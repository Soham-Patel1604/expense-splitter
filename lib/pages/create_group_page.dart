import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database/database.dart';
import '../repositories/group_repository.dart';
import '../repositories/user_repository.dart';
import '../models/friend_input.dart';
import '../utils/currency.dart';
import '../theme/app_theme.dart';

class CreateGroupPage extends StatefulWidget {
  const CreateGroupPage({super.key});

  @override
  State<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<CreateGroupPage> {
  final _eventNameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  late GroupRepository _groupRepository;
  late UserRepository _userRepository;
  String? _currentUserId;
  String? _currentUserName;

  final List<FriendInput> _friends = [];
  double _creatorAmountPaid = 0.0;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final database = AppDatabase();
    _groupRepository = GroupRepository(database: database);
    _userRepository = UserRepository(database: database);
    _loadCurrentUser();
  }

  @override
  void dispose() {
    _eventNameController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('currentUserId');

      if (userId != null) {
        _currentUserId = userId;
        final user = await _userRepository.getUserById(userId);
        if (!mounted) return;
        setState(() {
          _currentUserName = user?.name ?? 'You';
        });
      }
    } catch (e) {
      debugPrint('Error loading current user: $e');
    }
  }

  /// Why [name] can't be added, or null if it can. People are matched by
  /// name, so the same name twice would be the same person twice.
  String? _duplicateFriendError(String name) {
    final key = normalizeName(name).toLowerCase();
    if (_currentUserName != null &&
        normalizeName(_currentUserName!).toLowerCase() == key) {
      return "That's you — you're already in this event";
    }
    if (_friends.any((f) => normalizeName(f.name).toLowerCase() == key)) {
      return '${normalizeName(name)} is already added';
    }
    return null;
  }

  Future<void> _showAddFriendDialog() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final amountController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<FriendInput>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Friend'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name *',
                  hintText: 'Enter friend\'s name',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Name is required';
                  }
                  return _duplicateFriendError(value);
                },
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: phoneController,
                decoration: const InputDecoration(
                  labelText: 'Phone (Optional)',
                  hintText: 'Enter phone number',
                ),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: amountController,
                decoration: InputDecoration(
                  labelText: 'Amount Paid',
                  hintText: 'Enter amount paid by friend',
                  prefixText: '$currencySymbol ',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) {
                  if (value != null && value.isNotEmpty) {
                    final amount = double.tryParse(value);
                    if (amount == null || amount < 0) {
                      return 'Please enter a valid amount';
                    }
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                final amountPaid = amountController.text.trim().isEmpty
                    ? 0.0
                    : double.parse(amountController.text.trim());

                final friend = FriendInput(
                  name: normalizeName(nameController.text),
                  phone: phoneController.text.trim().isEmpty
                      ? null
                      : phoneController.text.trim(),
                  amountPaid: amountPaid,
                );

                Navigator.of(context).pop(friend);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    nameController.dispose();
    phoneController.dispose();
    amountController.dispose();

    if (result != null && mounted) {
      setState(() {
        _friends.add(result);
      });
    }
  }

  Future<void> _showEditCreatorAmountDialog() async {
    final amountController = TextEditingController(
      text: _creatorAmountPaid > 0 ? _creatorAmountPaid.toStringAsFixed(2) : '',
    );
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your Payment'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: amountController,
            decoration: InputDecoration(
              labelText: 'Amount Paid',
              hintText: 'Enter amount you paid',
              prefixText: '$currencySymbol ',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
            validator: (value) {
              if (value != null && value.isNotEmpty) {
                final amount = double.tryParse(value);
                if (amount == null || amount < 0) {
                  return 'Please enter a valid amount';
                }
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                final amount = amountController.text.trim().isEmpty
                    ? 0.0
                    : double.parse(amountController.text.trim());
                Navigator.of(context).pop(amount);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    amountController.dispose();

    if (result != null && mounted) {
      setState(() {
        _creatorAmountPaid = result;
      });
    }
  }

  void _removeFriend(int index) {
    setState(() {
      _friends.removeAt(index);
    });
  }

  Future<void> _createEvent() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final currentUserId = _currentUserId;
    if (currentUserId == null) {
      setState(() {
        _errorMessage = 'Your profile is still loading — try again.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _groupRepository.createGroupWithMembers(
        name: _eventNameController.text.trim(),
        currentUserId: currentUserId,
        friends: _friends,
        creatorAmountPaid: _creatorAmountPaid,
      );

      if (mounted) {
        Navigator.of(context).pop(true); // Signal that group was created
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Failed to create event: ${e.toString().replaceAll('Exception: ', '')}';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final TextTheme textTheme = theme.textTheme;

    return Scaffold(
      appBar: AppBar(),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Screen title (32) + one friendly helper line (16)
                Text('Create Event', style: textTheme.displayLarge),
                const SizedBox(height: 8),
                Text(
                  'Name your event, then add the friends you are splitting with.',
                  style: textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),

                // Event Details Section
                Text('Event Details', style: textTheme.titleMedium),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _eventNameController,
                  // Global InputDecorationTheme handles the field styling.
                  decoration: const InputDecoration(
                    labelText: 'Event Name *',
                    hintText: 'e.g. Goa Trip, Flatmates, Birthday Party',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Event name is required';
                    }
                    return null;
                  },
                  enabled: !_isLoading,
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 24),

                // Members Section
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Members', style: textTheme.titleMedium),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${_friends.length + 1} member${_friends.length + 1 == 1 ? '' : 's'}',
                          style: textTheme.labelMedium,
                        ),
                        Text(
                          'Total: ${formatCurrency(_creatorAmountPaid + _friends.fold(0.0, (sum, friend) => sum + friend.amountPaid))}',
                          style: textTheme.bodyLarge?.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Anything paid now is split equally among everyone in the '
                  'event. Add other expenses from the event page.',
                  style: textTheme.labelMedium,
                ),
                const SizedBox(height: 16),

                // Current User Card (always first)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: colorScheme.primary,
                      child: Text(
                        (_currentUserName ?? 'Y')[0].toUpperCase(),
                        style: textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    title: Text(
                      _currentUserName ?? 'You',
                      style: textTheme.bodyLarge,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'You (Event creator)',
                          style: textTheme.labelMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Paid: ${formatCurrency(_creatorAmountPaid)}',
                          style: textTheme.labelLarge?.copyWith(
                            color: _creatorAmountPaid > 0
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    trailing: IconButton(
                      icon: Icon(Icons.edit, color: colorScheme.primary),
                      onPressed: _isLoading
                          ? null
                          : _showEditCreatorAmountDialog,
                    ),
                    onTap: _isLoading ? null : _showEditCreatorAmountDialog,
                  ),
                ),
                const SizedBox(height: 8),

                // Friends List
                ...List.generate(_friends.length, (index) {
                  final friend = _friends[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: colorScheme.primaryContainer,
                          child: Text(
                            friend.name[0].toUpperCase(),
                            style: textTheme.bodyLarge?.copyWith(
                              color: colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        title: Text(friend.name, style: textTheme.bodyLarge),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              friend.phone ?? 'No phone number',
                              style: textTheme.labelMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Paid: ${formatCurrency(friend.amountPaid)}',
                              style: textTheme.labelLarge?.copyWith(
                                color: friend.amountPaid > 0
                                    ? colorScheme.primary
                                    : colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.remove_circle,
                            color: colorScheme.error,
                          ),
                          onPressed: _isLoading
                              ? null
                              : () => _removeFriend(index),
                        ),
                      ),
                    ),
                  );
                }),

                // Add Friend Button — the page's one warm accent (10% rule)
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isLoading ? null : _showAddFriendDialog,
                    icon: Container(
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(
                        color: AppTheme.warmAccent,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.person_add,
                        size: 16,
                        color: AppTheme.onWarm,
                      ),
                    ),
                    label: const Text('Add Friend'),
                  ),
                ),
                const SizedBox(height: 24),

                // Error message
                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(16),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onErrorContainer,
                      ),
                    ),
                  ),

                // Create Event Button
                SizedBox(
                  width: double.infinity,
                  child: _isLoading
                      ? ElevatedButton(
                          onPressed: null,
                          child: SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                colorScheme.onPrimary,
                              ),
                            ),
                          ),
                        )
                      : ElevatedButton(
                          onPressed: _createEvent,
                          child: const Text('Create Event'),
                        ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
