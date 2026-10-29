import 'package:flutter/material.dart';
import '../database/database.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../repositories/group_repository.dart';
import '../utils/currency.dart';

/// Spending insights for one event: totals, category breakdown and where
/// every member stands. Uses the same balances as the Settle tab.
class ExpenseInsightsPage extends StatefulWidget {
  final GroupBalanceView groupBalanceView;

  const ExpenseInsightsPage({super.key, required this.groupBalanceView});

  @override
  State<ExpenseInsightsPage> createState() => _ExpenseInsightsPageState();
}

class _ExpenseInsightsPageState extends State<ExpenseInsightsPage> {
  late GroupRepository _groupRepository;
  late String _groupName;
  GroupExpenseStats? _stats;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _groupName = widget.groupBalanceView.group.name;
    _groupRepository = GroupRepository(database: AppDatabase());
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final groupId = widget.groupBalanceView.group.id;
      final stats = await _groupRepository.getGroupExpenseStats(groupId);
      final group = await _groupRepository.getGroupById(groupId);

      if (!mounted) return;
      setState(() {
        if (group != null) _groupName = group.name;
        _stats = stats;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load insights: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? _buildError()
          : RefreshIndicator(
              onRefresh: _loadStats,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Insights',
                    style: Theme.of(context).textTheme.displayLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _groupName,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  _buildSummaryCard(),
                  const SizedBox(height: 16),
                  if (_stats!.hasData) ...[
                    _buildCategoryCard(),
                    const SizedBox(height: 16),
                    _buildMembersCard(),
                  ] else
                    _buildNoExpensesCard(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadStats,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard() {
    final stats = _stats!;
    final memberCount = stats.memberStats.length;
    final averagePerMember = memberCount > 0
        ? stats.totalAmount / memberCount
        : 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCardTitle(Icons.event, 'Summary'),
            const SizedBox(height: 16),
            _buildInfoRow(
              'Total Spent',
              formatCurrency(stats.totalAmount),
              Icons.payments,
            ),
            const SizedBox(height: 16),
            _buildInfoRow('Total Members', '$memberCount', Icons.group),
            const SizedBox(height: 16),
            _buildInfoRow(
              'Average per Member',
              formatCurrency(averagePerMember),
              Icons.person,
            ),
            const SizedBox(height: 16),
            _buildInfoRow(
              'Expenses Logged',
              '${stats.expenseCount}',
              Icons.receipt_long,
            ),
            const SizedBox(height: 16),
            _buildInfoRow(
              'Average Expense',
              formatCurrency(stats.averageExpense),
              Icons.trending_up,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryCard() {
    final scheme = Theme.of(context).colorScheme;
    final categoryTotals = _stats!.categoryTotals;
    final maxCategorySpend = categoryTotals.values.fold<double>(
      0.0,
      (maxValue, value) => value > maxValue ? value : maxValue,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCardTitle(Icons.analytics_outlined, 'Category Breakdown'),
            const SizedBox(height: 16),
            ...categoryTotals.entries.map((entry) {
              final label = expenseCategories[entry.key] ?? entry.key;
              final progress = maxCategorySpend <= 0
                  ? 0.0
                  : entry.value / maxCategorySpend;

              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        Text(
                          formatCurrency(entry.value),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: progress,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Paid, share and net position per member. Net is "+" when the group
  /// owes them and "−" when they owe the group.
  Widget _buildMembersCard() {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCardTitle(Icons.people_outline, 'Member Net Position'),
            const SizedBox(height: 8),
            Text(
              '+ is owed money · − owes money (after payments marked as paid)',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 16),
            ..._stats!.memberStats.map((member) {
              final net = member.netBalance;
              final color = net > 0
                  ? scheme.primary
                  : net < 0
                  ? scheme.error
                  : scheme.onSurfaceVariant;

              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: scheme.primaryContainer,
                      child: Text(
                        member.userName.isNotEmpty
                            ? member.userName[0].toUpperCase()
                            : '?',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            member.userName,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          Text(
                            'Paid ${formatCurrency(member.amountPaid)} · '
                            'Share ${formatCurrency(member.amountOwed)}',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ],
                      ),
                    ),
                    Text(
                      net == 0 ? 'Settled' : formatSignedCurrency(net),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildNoExpensesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: Text(
            'No expenses yet — insights appear once you add one.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
    );
  }

  Widget _buildCardTitle(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary, size: 24),
        const SizedBox(width: 16),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
      ],
    );
  }
}
