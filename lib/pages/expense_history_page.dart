import 'package:flutter/material.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../models/settlement.dart';
import '../database/database.dart';
import '../repositories/group_repository.dart';
import '../theme/app_theme.dart';
import '../utils/currency.dart';

/// Type of entry in the activity timeline
enum TimelineEntryType { expense, settlement }

/// Unified wrapper representing either an Expense or a Settlement
class TimelineEntry {
  final TimelineEntryType type;
  final Expense? expense;
  final Settlement? settlement;
  final int timestamp;

  TimelineEntry.fromExpense(Expense item)
    : type = TimelineEntryType.expense,
      expense = item,
      settlement = null,
      timestamp = item.createdAt;

  TimelineEntry.fromSettlement(Settlement item)
    : type = TimelineEntryType.settlement,
      expense = null,
      settlement = item,
      timestamp = item.paidAt ?? 0;

  bool get isExpense => type == TimelineEntryType.expense;
  bool get isSettlement => type == TimelineEntryType.settlement;
}

class ExpenseHistoryPage extends StatefulWidget {
  final GroupBalanceView groupBalanceView;

  const ExpenseHistoryPage({super.key, required this.groupBalanceView});

  @override
  State<ExpenseHistoryPage> createState() => _ExpenseHistoryPageState();
}

class _ExpenseHistoryPageState extends State<ExpenseHistoryPage> {
  late GroupRepository _groupRepository;
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedCategories = {};
  List<TimelineEntry> _entries = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final database = AppDatabase();
    _groupRepository = GroupRepository(database: database);
    _loadHistoryData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHistoryData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final groupId = widget.groupBalanceView.group.id;

      // 1. Fetch expenses and completed settlements from database
      final expenses = await _groupRepository.getGroupExpenses(groupId);
      final settlements = await _groupRepository.getGroupSettlements(groupId);

      // 2. Merge into unified list
      final List<TimelineEntry> combined = [
        ...expenses.map((e) => TimelineEntry.fromExpense(e)),
        ...settlements.map((s) => TimelineEntry.fromSettlement(s)),
      ];

      // 3. Sort chronologically descending (most recent first)
      combined.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      if (!mounted) return;
      setState(() {
        _entries = combined;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load history: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  /// Client-side filter: description/payer/note search + category chips.
  List<TimelineEntry> _getFilteredEntries() {
    final query = _searchController.text.trim().toLowerCase();

    return _entries.where((entry) {
      final matchesQuery = query.isEmpty || _matchesQuery(entry, query);
      // Settlements carry no category, so a category filter shows expenses only.
      final matchesCategory =
          _selectedCategories.isEmpty ||
          (entry.isExpense &&
              _selectedCategories.contains(entry.expense!.category));
      return matchesQuery && matchesCategory;
    }).toList();
  }

  bool _matchesQuery(TimelineEntry entry, String query) {
    if (entry.isExpense) {
      final expense = entry.expense!;
      return (expense.description ?? '').toLowerCase().contains(query) ||
          expense.paidByUserName.toLowerCase().contains(query) ||
          (expense.note ?? '').toLowerCase().contains(query);
    }
    final settlement = entry.settlement!;
    return settlement.fromUserName.toLowerCase().contains(query) ||
        settlement.toUserName.toLowerCase().contains(query);
  }

  bool get _hasActiveFilter =>
      _searchController.text.trim().isNotEmpty ||
      _selectedCategories.isNotEmpty;

  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _selectedCategories.clear();
    });
  }

  String _formatDateTime(int timestamp) {
    if (timestamp <= 0) return 'Date unknown';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year;

    final hourInt = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final hour = hourInt.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';

    return '$day/$month/$year $hour:$minute $period';
  }

  IconData _getCategoryIcon(String category) {
    switch (category.toLowerCase()) {
      case 'food':
        return Icons.restaurant;
      case 'transport':
        return Icons.directions_car;
      case 'accommodation':
        return Icons.hotel;
      case 'entertainment':
        return Icons.movie;
      case 'groceries':
        return Icons.shopping_basket;
      case 'utilities':
        return Icons.power;
      case 'shopping':
        return Icons.shopping_bag;
      case 'health':
        return Icons.local_hospital;
      default:
        return Icons.receipt_long;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Plain AppBar: back arrow from the navigator, refresh as the one action.
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadHistoryData,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final ThemeData theme = Theme.of(context);
    final TextTheme textTheme = theme.textTheme;
    final ColorScheme colorScheme = theme.colorScheme;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 56, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(
                'Couldn\'t load activity',
                textAlign: TextAlign.center,
                style: textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadHistoryData,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_entries.isEmpty) {
      return Column(
        children: [
          _buildIntro(),
          Expanded(child: _buildEmptyState()),
        ],
      );
    }

    final filteredEntries = _getFilteredEntries();

    return Column(
      children: [
        _buildIntro(),
        _buildSearchBar(),
        _buildCategoryChips(),
        _buildFilterSummaryBar(
          totalCount: _entries.length,
          filteredCount: filteredEntries.length,
          hasActiveFilter: _hasActiveFilter,
        ),
        const Divider(height: 1),
        Expanded(
          child: filteredEntries.isEmpty
              ? _buildNoMatchesState()
              : RefreshIndicator(
                  onRefresh: _loadHistoryData,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: filteredEntries.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 16),
                    itemBuilder: (context, index) {
                      final entry = filteredEntries[index];
                      if (entry.isExpense) {
                        return _buildExpenseCard(entry.expense!);
                      }
                      return _buildSettlementCard(entry.settlement!);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  /// Screen title (32) + one friendly helper line (16) — the sibling idiom.
  Widget _buildIntro() {
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Activity', style: textTheme.displayLarge),
          const SizedBox(height: 8),
          Text(
            'Everything spent and settled in '
            '${widget.groupBalanceView.group.name}, newest first.',
            style: textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: TextField(
        controller: _searchController,
        // Global InputDecorationTheme supplies fill, border and padding.
        decoration: InputDecoration(
          hintText: 'Search description, payer, note...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchController.clear();
                    setState(() {});
                  },
                )
              : null,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  /// Horizontal category row, lazily built chip by chip.
  Widget _buildCategoryChips() {
    final List<MapEntry<String, String>> categories = expenseCategories.entries
        .toList();

    return SizedBox(
      height: 52,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: categories.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: const Text('All'),
                selected: _selectedCategories.isEmpty,
                onSelected: (selected) {
                  if (selected) {
                    setState(_selectedCategories.clear);
                  }
                },
              ),
            );
          }

          final MapEntry<String, String> category = categories[index - 1];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(category.value),
              selected: _selectedCategories.contains(category.key),
              onSelected: (selected) {
                setState(() {
                  if (selected) {
                    _selectedCategories.add(category.key);
                  } else {
                    _selectedCategories.remove(category.key);
                  }
                });
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildFilterSummaryBar({
    required int totalCount,
    required int filteredCount,
    required bool hasActiveFilter,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            hasActiveFilter
                ? 'Showing $filteredCount of $totalCount items'
                : 'Total $totalCount items',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          if (hasActiveFilter)
            TextButton(
              onPressed: _clearFilters,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('Clear Filters'),
            ),
        ],
      ),
    );
  }

  /// The page's one warm accent — a friendly nudge, not a warning.
  Widget _buildEmptyState() {
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history, size: 56, color: AppTheme.warmAccent),
            const SizedBox(height: 16),
            Text('No activity yet', style: textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Expenses and settled-up payments will appear here the moment '
              'they happen.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoMatchesState() {
    final ThemeData theme = Theme.of(context);
    final TextTheme textTheme = theme.textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('Nothing matches that', style: textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Try a different search, or clear the category chips to see '
              'everything again.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _clearFilters,
              icon: const Icon(Icons.clear_all),
              label: const Text('Clear Filters'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpenseCard(Expense expense) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final TextTheme textTheme = theme.textTheme;

    final categoryLabel =
        expenseCategories[expense.category] ?? expense.category;
    final dateStr = _formatDateTime(expense.createdAt);
    final description =
        (expense.description != null && expense.description!.isNotEmpty)
        ? expense.description!
        : 'Expense';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: colorScheme.primaryContainer,
                  child: Icon(
                    _getCategoryIcon(expense.category),
                    color: colorScheme.onPrimaryContainer,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        description,
                        style: textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Paid by ${expense.paidByUserName}',
                        style: textTheme.labelMedium,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatCurrency(expense.amount),
                  textAlign: TextAlign.right,
                  style: textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Category pill: neutral tonal fill, same idea as the
                // "Settled" chip on the events list.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    categoryLabel,
                    style: textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Row(
                  children: [
                    Icon(
                      Icons.access_time,
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(dateStr, style: textTheme.labelMedium),
                  ],
                ),
              ],
            ),
            if (expense.note != null && expense.note!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Note: ${expense.note!}',
                style: textTheme.labelMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSettlementCard(Settlement settlement) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final TextTheme textTheme = theme.textTheme;

    final dateStr = _formatDateTime(settlement.paidAt ?? 0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: colorScheme.primaryContainer,
                  child: Icon(
                    Icons.check_circle,
                    color: colorScheme.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichText(
                        text: TextSpan(
                          style: textTheme.bodyLarge,
                          children: [
                            TextSpan(
                              text: settlement.fromUserName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const TextSpan(text: ' paid '),
                            TextSpan(
                              text: settlement.toUserName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          'Settlement',
                          style: textTheme.labelMedium?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatCurrency(settlement.amount),
                  textAlign: TextAlign.right,
                  style: textTheme.labelLarge?.copyWith(
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(
                  Icons.access_time,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(dateStr, style: textTheme.labelMedium),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
