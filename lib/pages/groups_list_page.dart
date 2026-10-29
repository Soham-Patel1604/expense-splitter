import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database/database.dart';
import '../repositories/group_repository.dart';
import '../models/group.dart';
import '../main.dart';
import '../theme/app_theme.dart';
import '../utils/currency.dart';
import 'create_group_page.dart';
import 'group_details_page.dart';
import 'login_page.dart';
import 'profile_page.dart';

class GroupsListPage extends StatefulWidget {
  const GroupsListPage({super.key});

  @override
  State<GroupsListPage> createState() => _GroupsListPageState();
}

class _GroupsListPageState extends State<GroupsListPage> {
  late GroupRepository _groupRepository;
  String? _currentUserId; // Make nullable to handle loading state
  int _refreshKey = 0; // Add refresh key to trigger rebuilds
  // Cached so plain rebuilds (theme change, popups) don't re-run the queries —
  // only _refreshData() invalidates it.
  Future<_HomeData>? _homeFuture;

  @override
  void initState() {
    super.initState();
    final database = AppDatabase();
    _groupRepository = GroupRepository(database: database);
    _loadCurrentUserId();
  }

  Future<void> _loadCurrentUserId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('currentUserId');
      if (userId != null && mounted) {
        setState(() {
          _currentUserId = userId;
        });
      }
    } catch (e) {
      debugPrint('Error loading current user ID: $e');
    }
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'Your events stay on this device. Log in with the same name to see '
          'them again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('currentUserId');

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginPage()),
      );
    }
  }

  void _refreshData() {
    setState(() {
      _refreshKey++;
      _homeFuture = null; // force a fresh load on next build
    });
  }

  Future<void> _navigateToProfile() async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => const ProfilePage()),
    );

    // Refresh unconditionally so a renamed profile shows up straight away.
    _refreshData();
  }

  void _showThemeDialog() {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Choose Theme'),
          // RadioGroup owns groupValue/onChanged for the tiles below.
          // The tiles must NOT set groupValue or onChanged themselves:
          // those parameters were deprecated after Flutter v3.32.0.
          content: RadioGroup<ThemeMode>(
            groupValue: themeNotifier.value,
            onChanged: (ThemeMode? value) {
              if (value != null) {
                updateThemeMode(value);
                Navigator.pop(dialogContext);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                RadioListTile<ThemeMode>(
                  title: Text('System Default'),
                  value: ThemeMode.system,
                ),
                RadioListTile<ThemeMode>(
                  title: Text('Light'),
                  value: ThemeMode.light,
                ),
                RadioListTile<ThemeMode>(
                  title: Text('Dark'),
                  value: ThemeMode.dark,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _navigateToCreateGroup() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => const CreateGroupPage()),
    );

    // If a group was created successfully, refresh the data
    if (result == true) {
      _refreshData();
    }
  }

  /// Loads everything the home screen renders in one go. The overall balance
  /// is the sum of the per-event balances, so the hero and the event cards
  /// always agree.
  Future<_HomeData> _loadHomeData(String userId) async {
    final groups = await _groupRepository.getGroupsWithBalance(userId);
    final overallBalance = groups.fold<double>(
      0.0,
      (sum, view) => sum + view.netBalance,
    );

    var memberCounts = <String, int>{};
    try {
      memberCounts = await _groupRepository.getMemberCountsForUser(userId);
    } catch (e) {
      // A missing count only hides a meta line — never break the list.
      debugPrint('Error loading member counts: $e');
    }

    return _HomeData(
      overallBalance: overallBalance,
      groups: groups,
      memberCounts: memberCounts,
    );
  }

  Future<void> _deleteGroup(String groupId) async {
    // Captured before the first await so the SnackBar stays on-palette.
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    try {
      await _groupRepository.deleteGroup(groupId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: colorScheme.onInverseSurface),
                const SizedBox(width: 8),
                const Text('Event deleted'),
              ],
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      _refreshData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting event: ${e.toString()}')),
        );
      }
    }
  }

  void _showDeleteGroupDialog(Group group) {
    // Destructive action reads as error; dialog chrome comes from dialogTheme.
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Event'),
        content: Text(
          'Are you sure you want to delete "${group.name}"?\n\nThis will permanently delete all expenses, settlements, and member records for this event. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _deleteGroup(group.id);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.error,
              foregroundColor: colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show loading indicator until current user ID is loaded
    if (_currentUserId == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Events'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'profile') {
                _navigateToProfile();
              } else if (value == 'theme') {
                _showThemeDialog();
              } else if (value == 'logout') {
                _handleLogout();
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem<String>(
                value: 'profile',
                child: Row(
                  children: [
                    Icon(Icons.person_outline, size: 20),
                    SizedBox(width: 16),
                    Text('Profile'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'theme',
                child: Row(
                  children: [
                    Icon(Icons.brightness_6, size: 20),
                    SizedBox(width: 16),
                    Text('Theme'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 20),
                    SizedBox(width: 16),
                    Text('Logout'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: FutureBuilder<_HomeData>(
        key: ValueKey(_refreshKey), // Add key to force rebuild on refresh
        future: _homeFuture ??= _loadHomeData(_currentUserId!),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text('Error loading events', style: textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      'Your events will show up here in a moment.',
                      style: textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            );
          }

          final _HomeData? data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }

          return SingleChildScrollView(
            child: Padding(
              // Extra bottom space so the + button never covers the last
              // event's balance.
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Balance hero — the one number that matters
                  _buildBalanceHero(context, data.overallBalance),
                  const SizedBox(height: 24),

                  if (data.groups.isEmpty)
                    _buildEmptyState(context)
                  else ...[
                    Text('Your events', style: textTheme.titleMedium),
                    const SizedBox(height: 16),
                    _buildGroupsList(context, data.groups, data.memberCounts),
                  ],
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _navigateToCreateGroup,
        tooltip: 'Add Event',
        child: const Icon(Icons.add),
      ),
    );
  }

  /// Overall balance, framed the way a friend would say it.
  Widget _buildBalanceHero(BuildContext context, double balance) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final TextTheme textTheme = theme.textTheme;

    final bool isOwed = balance > 0;
    final bool isOwing = balance < 0;

    String headline;
    String caption;
    Color headlineColor;

    if (isOwed) {
      headline = "You're owed ${formatCurrency(balance)}";
      caption = "Across all your events, you're ahead.";
      headlineColor = colorScheme.primary;
    } else if (isOwing) {
      headline = 'You owe ${formatCurrency(-balance)}';
      caption = "Across all your events, you're due to settle up.";
      headlineColor = colorScheme.error;
    } else {
      headline = 'All settled up 🎉';
      caption = 'Nothing to pay or chase right now.';
      headlineColor = colorScheme.onSurface;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              headline,
              style: textTheme.displayLarge?.copyWith(color: headlineColor),
            ),
            const SizedBox(height: 8),
            Text(caption, style: textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The page's one warm accent — a friendly nudge, not a warning.
            const Icon(
              Icons.celebration_outlined,
              size: 56,
              color: AppTheme.warmAccent,
            ),
            const SizedBox(height: 16),
            Text('No events yet', style: textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Tap + to plan something fun and split the bill in a couple of taps.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupsList(
    BuildContext context,
    List<GroupBalanceView> groupsWithBalance,
    Map<String, int> memberCounts,
  ) {
    final TextTheme textTheme = Theme.of(context).textTheme;

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: groupsWithBalance.length,
      itemBuilder: (context, index) {
        final groupBalance = groupsWithBalance[index];
        final balance = groupBalance.netBalance;
        final int memberCount = memberCounts[groupBalance.group.id] ?? 0;

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      GroupDetailsPage(groupBalanceView: groupBalance),
                ),
              );

              // Refresh so renames made in details are reflected here
              _refreshData();
            },
            onLongPress: () => _showDeleteGroupDialog(groupBalance.group),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          groupBalance.group.name,
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          memberCount == 1
                              ? '1 member'
                              : '$memberCount members',
                          style: textTheme.labelMedium,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  _buildBalanceChip(context, balance),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Per-event balance as a small tonal chip: blue when you are ahead, red
  /// when you owe, neutral when it is already square.
  Widget _buildBalanceChip(BuildContext context, double balance) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final TextTheme textTheme = theme.textTheme;

    final bool isOwed = balance > 0;
    final bool isOwing = balance < 0;

    Color background;
    Color foreground;
    String label;

    if (isOwed) {
      background = colorScheme.primaryContainer;
      foreground = colorScheme.onPrimaryContainer;
      label = formatSignedCurrency(balance);
    } else if (isOwing) {
      background = colorScheme.errorContainer;
      foreground = colorScheme.onErrorContainer;
      label = formatSignedCurrency(balance);
    } else {
      background = colorScheme.surfaceContainerHighest;
      foreground = colorScheme.onSurfaceVariant;
      label = 'Settled';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        style: textTheme.labelLarge?.copyWith(color: foreground),
      ),
    );
  }
}

/// Everything the home screen renders, loaded together so the hero and the
/// list never disagree.
class _HomeData {
  final double overallBalance;
  final List<GroupBalanceView> groups;
  final Map<String, int> memberCounts;

  const _HomeData({
    required this.overallBalance,
    required this.groups,
    required this.memberCounts,
  });
}
