import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../models/group_member.dart';
import '../models/settlement.dart';
import '../database/database.dart';
import '../repositories/group_repository.dart';
import '../utils/currency.dart';
import '../utils/export.dart';
import 'add_expense_page.dart';
import 'expense_history_page.dart';
import 'expense_insights_page.dart';

class GroupDetailsPage extends StatefulWidget {
  final GroupBalanceView groupBalanceView;

  const GroupDetailsPage({super.key, required this.groupBalanceView});

  @override
  State<GroupDetailsPage> createState() => _GroupDetailsPageState();
}

class _GroupDetailsPageState extends State<GroupDetailsPage> {
  late GroupRepository _groupRepository;
  late String _groupName;
  List<GroupMember> _members = [];
  List<Expense> _expenses = [];
  List<Settlement> _pendingSettlements = [];
  List<Settlement> _completedSettlements = [];
  String? _currentUserId;
  double _myBalance = 0.0;
  bool _isLoading = true;
  String? _errorMessage;

  // Which of the 3 bottom tabs is visible (Settle / Expenses / More).
  int _tabIndex = 0;
  static const int _moreTabIndex = 2;

  @override
  void initState() {
    super.initState();
    _groupName = widget.groupBalanceView.group.name;
    final database = AppDatabase();
    _groupRepository = GroupRepository(database: database);
    _loadGroupData();
  }

  Future<void> _loadGroupData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final groupId = widget.groupBalanceView.group.id;
      final prefs = await SharedPreferences.getInstance();
      final currentUserId = prefs.getString('currentUserId');

      // Load members with their payments
      final members = await _groupRepository.getGroupMembersWithPayments(
        groupId,
      );

      // Load all logged expenses
      final expenses = await _groupRepository.getGroupExpenses(groupId);

      // Load pending settlements
      final pending = await _groupRepository.calculatePendingSettlements(
        groupId,
      );

      // Load completed settlements
      final completed = await _groupRepository.getGroupSettlements(groupId);

      // Your own position — the same number the Events screen shows
      final balances = await _groupRepository.getGroupBalances(groupId);

      // Load the group itself so renames are reflected
      final group = await _groupRepository.getGroupById(groupId);

      if (!mounted) return;
      setState(() {
        if (group != null) {
          _groupName = group.name;
        }
        _currentUserId = currentUserId;
        _members = members;
        _expenses = expenses;
        _pendingSettlements = pending;
        _completedSettlements = completed;
        _myBalance = balances[currentUserId] ?? 0.0;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load group data: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  /// Shared snackbar helper — uses the theme's SnackBar (inverseSurface), so
  /// the same message reads correctly in light AND dark mode.
  void _showSnack(
    String message, {
    bool error = false,
    SnackBarAction? action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              error ? Icons.error_outline : Icons.check_circle,
              color: scheme.onInverseSurface,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        action: action,
        duration: Duration(seconds: action != null ? 5 : 2),
      ),
    );
  }

  Future<void> _markAsPaid(Settlement settlement, double amount) async {
    try {
      final settlementId = await _groupRepository.markSettlementAsPaid(
        settlement,
        amount: amount,
      );

      if (mounted) {
        _showSnack(
          '✓ ${formatCurrency(amount)} marked as paid',
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _undoPayment(settlementId),
          ),
        );
      }

      // Reload data to reflect changes
      await _loadGroupData();
    } catch (e) {
      if (mounted) {
        _showSnack('Error: ${e.toString()}', error: true);
      }
    }
  }

  Future<void> _undoPayment(String settlementId) async {
    try {
      await _groupRepository.deleteSettlement(settlementId);
      if (mounted) {
        _showSnack('Payment removed');
      }
      await _loadGroupData();
    } catch (e) {
      if (mounted) {
        _showSnack('Error: ${e.toString()}', error: true);
      }
    }
  }

  void _showUndoPaymentDialog(Settlement settlement) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Undo payment?'),
        content: Text(
          'Remove "${settlement.fromUserName} paid ${settlement.toUserName} '
          '${formatCurrency(settlement.amount)}"? The amount goes back to '
          'pending.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _undoPayment(settlement.id);
            },
            child: const Text('Undo payment'),
          ),
        ],
      ),
    );
  }

  Future<void> _shareGroupSummary() async {
    try {
      final summary = await generateGroupSummary(
        _groupRepository,
        widget.groupBalanceView.group.id,
      );
      await Share.share(summary, subject: '$_groupName - Summary');
    } catch (e) {
      if (mounted) {
        _showSnack('Failed to share summary: ${e.toString()}', error: true);
      }
    }
  }

  Future<void> _navigateToEditExpense(Expense expense) async {
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AddExpensePage(
          groupBalanceView: widget.groupBalanceView,
          existingExpense: expense,
        ),
      ),
    );

    if (result == true) {
      await _loadGroupData();
    }
  }

  void _showDeleteExpenseDialog(Expense expense) {
    final scheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Expense'),
        content: Text(
          'Are you sure you want to delete "${expense.description ?? 'Expense'}" (${formatCurrency(expense.amount)})?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _deleteExpense(expense.id);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteExpense(String expenseId) async {
    try {
      await _groupRepository.deleteExpense(expenseId);

      if (mounted) {
        _showSnack('✓ Expense deleted successfully');
      }

      await _loadGroupData();
    } catch (e) {
      if (mounted) {
        _showSnack('Error deleting expense: ${e.toString()}', error: true);
      }
    }
  }

  Future<void> _showEditGroupModal() async {
    final nameController = TextEditingController(text: _groupName);
    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (bottomSheetContext) => StatefulBuilder(
        builder: (context, setModalState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              left: 16,
              right: 16,
              top: 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Edit Event',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Rename Event Section
                  Form(
                    key: formKey,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: nameController,
                            decoration: const InputDecoration(
                              labelText: 'Event Name',
                            ),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return 'Event name cannot be empty';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () async {
                            if (!formKey.currentState!.validate()) {
                              return;
                            }
                            final newName = nameController.text.trim();
                            try {
                              await _groupRepository.updateGroupName(
                                widget.groupBalanceView.group.id,
                                newName,
                              );
                              if (!mounted) return;
                              setState(() {
                                _groupName = newName;
                              });
                              _showSnack('✓ Event name updated');
                              if (bottomSheetContext.mounted) {
                                Navigator.of(bottomSheetContext).pop();
                              }
                            } catch (e) {
                              if (!mounted) return;
                              _showSnack('Error: ${e.toString()}', error: true);
                            }
                          },
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 8),

                  // Members Section Header with Add Button
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Members (${_members.length})',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.of(bottomSheetContext).pop();
                          await _showAddMemberDialog();
                        },
                        icon: const Icon(Icons.person_add, size: 18),
                        label: const Text('Add Member'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Members List
                  ..._members.map(
                    (member) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: member.amountPaid > 0
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                        child: Text(
                          member.userName.isNotEmpty
                              ? member.userName[0].toUpperCase()
                              : '?',
                          style: TextStyle(
                            fontSize: 13,
                            color: member.amountPaid > 0
                                ? Theme.of(
                                    context,
                                  ).colorScheme.onPrimaryContainer
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      title: Text(member.userName),
                      subtitle: Text(
                        member.amountPaid > 0
                            ? 'Paid ${formatCurrency(member.amountPaid)}'
                            : 'No payments yet',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: member.amountPaid > 0
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );

    // F6 fix: one-shot controller is released once the sheet closes.
    nameController.dispose();
  }

  Future<void> _showAddMemberDialog() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final added = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Member'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name *',
                  hintText: 'Enter member\'s name',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Name is required';
                  }
                  return null;
                },
                textCapitalization: TextCapitalization.words,
                autofocus: true,
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
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                final name = nameController.text.trim();
                final phone = phoneController.text.trim().isEmpty
                    ? null
                    : phoneController.text.trim();

                try {
                  await _groupRepository.addNewMemberToGroup(
                    widget.groupBalanceView.group.id,
                    name,
                    phone,
                  );
                  if (context.mounted) {
                    Navigator.of(context).pop(true);
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          e.toString().replaceAll('Exception: ', ''),
                        ),
                      ),
                    );
                  }
                }
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    // F6 fix: one-shot controllers are released once the dialog closes.
    nameController.dispose();
    phoneController.dispose();

    if (added == true) {
      if (mounted) {
        _showSnack('✓ Member added successfully');
      }
      await _loadGroupData();
    }
  }

  void _navigateToHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            ExpenseHistoryPage(groupBalanceView: widget.groupBalanceView),
      ),
    );
  }

  Future<void> _navigateToAddExpense() async {
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            AddExpensePage(groupBalanceView: widget.groupBalanceView),
      ),
    );

    // Refresh data if expense was added
    if (result == true) {
      await _loadGroupData();
    }
  }

  void _goToTab(int index) {
    if (_tabIndex == index) return;
    setState(() {
      _tabIndex = index;
    });
  }

  Future<void> _navigateToInsights() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            ExpenseInsightsPage(groupBalanceView: widget.groupBalanceView),
      ),
    );
  }

  // ────────────────────────── Shell: dashboard + tabs ───────────────────────

  @override
  Widget build(BuildContext context) {
    final ready = !_isLoading && _errorMessage == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(_groupName),
        actions: [
          IconButton(
            icon: const Icon(Icons.insights),
            onPressed: _navigateToInsights,
            tooltip: 'Insights',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadGroupData,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? Center(
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
                      onPressed: _loadGroupData,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                _buildDashboardHeader(),
                Expanded(
                  child: IndexedStack(
                    index: _tabIndex,
                    children: [
                      _settleTab(),
                      _expensesTab(),
                      _moreTab(),
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: ready
          ? NavigationBar(
              selectedIndex: _tabIndex,
              onDestinationSelected: _goToTab,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.handshake_outlined),
                  selectedIcon: Icon(Icons.handshake),
                  label: 'Settle',
                ),
                NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  selectedIcon: Icon(Icons.receipt_long),
                  label: 'Expenses',
                ),
                NavigationDestination(
                  icon: Icon(Icons.more_horiz),
                  label: 'More',
                ),
              ],
            )
          : null,
      floatingActionButton: ready && _tabIndex != _moreTabIndex
          ? FloatingActionButton.extended(
              onPressed: _navigateToAddExpense,
              icon: const Icon(Icons.add),
              label: const Text('Add Expense'),
            )
          : null,
    );
  }

  /// Compact always-visible dashboard: three tappable summary cards — total
  /// spent, payments left, and your own position in this event.
  Widget _buildDashboardHeader() {
    final totalSpent = _expenses.fold<double>(
      0.0,
      (sum, e) => sum + e.amount,
    );
    final pending = _pendingSettlements.length;
    final myBalanceLabel = _myBalance > 0
        ? 'you are owed'
        : _myBalance < 0
        ? 'you owe'
        : 'you are square';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: _dashboardCard(
              value: formatCurrency(totalSpent),
              label: 'Spent',
              onTap: () => _goToTab(1),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _dashboardCard(
              value: pending > 0 ? '$pending' : '🎉',
              label: pending > 0 ? 'to settle' : 'All settled',
              highlight: pending > 0,
              onTap: () => _goToTab(0),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _dashboardCard(
              value: formatSignedCurrency(_myBalance),
              label: myBalanceLabel,
              valueColor: _myBalance > 0
                  ? Theme.of(context).colorScheme.primary
                  : _myBalance < 0
                  ? Theme.of(context).colorScheme.error
                  : null,
              onTap: _navigateToInsights,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dashboardCard({
    required String value,
    required String label,
    VoidCallback? onTap,
    bool highlight = false,
    Color? valueColor,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: highlight ? scheme.primaryContainer : scheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // FittedBox guards long currency strings from overflowing the
              // narrow one-third-width card.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: highlight ? scheme.onPrimaryContainer : valueColor,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: highlight ? scheme.onPrimaryContainer : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────────────────── Tab 1: Settle ──────────────────────────────

  /// Extra bottom space so the floating "Add Expense" button never covers the
  /// last card's amount or buttons.
  static const EdgeInsets _tabPadding = EdgeInsets.fromLTRB(16, 16, 16, 96);

  Widget _settleTab() {
    return RefreshIndicator(
      onRefresh: _loadGroupData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: _tabPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeader(
                'Pending Settlements',
                _pendingSettlements.length,
              ),
              const SizedBox(height: 16),
              _pendingSettlements.isEmpty
                  ? _buildAllSettledCard()
                  : _buildPendingSettlementsList(),
              if (_completedSettlements.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),
                _buildSectionHeader(
                  'Completed Settlements',
                  _completedSettlements.length,
                ),
                const SizedBox(height: 16),
                _buildCompletedSettlementsList(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────── Tab 2: Expenses ──────────────────────────────

  Widget _expensesTab() {
    return RefreshIndicator(
      onRefresh: _loadGroupData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: _tabPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeader('Expenses', _expenses.length),
              const SizedBox(height: 16),
              _expenses.isEmpty ? _buildNoExpensesCard() : _buildExpensesList(),
            ],
          ),
        ),
      ),
    );
  }

  // ──────────────────────────── Tab 3: More ─────────────────────────────────

  /// Insights / share / edit / history live here instead of a crowded AppBar.
  Widget _moreTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          leading: const Icon(Icons.insights_outlined),
          title: const Text('Expense insights'),
          subtitle: const Text('Totals, categories and who stands where'),
          onTap: _navigateToInsights,
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Edit event'),
          subtitle: const Text('Rename this event or manage members'),
          onTap: _showEditGroupModal,
        ),
        ListTile(
          leading: const Icon(Icons.share_outlined),
          title: const Text('Share summary'),
          subtitle: const Text('Send the breakdown to your friends'),
          onTap: _shareGroupSummary,
        ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Activity history'),
          subtitle: const Text('Every expense and payment, in order'),
          onTap: _navigateToHistory,
        ),
      ],
    );
  }

  // ─────────────────────────── Section builders ─────────────────────────────

  Widget _buildNoExpensesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: Text(
            'No expenses yet — tap + to add the first one.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
    );
  }

  String _splitLabel(Expense expense) {
    switch (expense.splitType) {
      case 'unequal':
        return 'Unequal';
      case 'percentage':
        return 'By %';
      default:
        return 'Equal';
    }
  }

  Widget _buildExpensesList() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: _expenses.map((expense) {
        final date = DateTime.fromMillisecondsSinceEpoch(expense.createdAt);
        final dateStr = '${date.day}/${date.month}/${date.year}';
        final categoryLabel =
            expenseCategories[expense.category] ?? expense.category;

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(
                    Icons.receipt_long,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        expense.description?.isNotEmpty == true
                            ? expense.description!
                            : 'Expense',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Paid by ${expense.paidByUserName} • $dateStr',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Category: $categoryLabel • ${_splitLabel(expense)} • ${expense.participantIds.length} participant${expense.participantIds.length == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      if (_currentUserId != null &&
                          expense.shares.containsKey(_currentUserId)) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Your share: ${formatCurrency(expense.shareOf(_currentUserId!))}',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: scheme.primary),
                        ),
                      ],
                      if (expense.note != null &&
                          expense.note!.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Note: ${expense.note}',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(fontStyle: FontStyle.italic),
                        ),
                      ],
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatCurrency(expense.amount),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => _navigateToEditExpense(expense),
                          tooltip: 'Edit Expense',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _showDeleteExpenseDialog(expense),
                          tooltip: 'Delete Expense',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          color: scheme.error,
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: count > 0
                ? scheme.tertiaryContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: count > 0
                  ? scheme.onTertiaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAllSettledCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            Icon(Icons.celebration, size: 48, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              'All Settled! 🎉',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'No pending payments',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Pending payments, phrased from your side: "You owe X" shows −₹ in red,
  /// "X owes you" shows +₹ in blue, anyone else's debt stays neutral.
  Widget _buildPendingSettlementsList() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: _pendingSettlements.map((settlement) {
        final youPay = settlement.fromUserId == _currentUserId;
        final youReceive = settlement.toUserId == _currentUserId;
        final fromName = youPay ? 'You' : settlement.fromUserName;
        final toName = youReceive ? 'you' : settlement.toUserName;
        final verb = youPay ? ' owe ' : ' owes ';

        final Color chipColor;
        final Color chipTextColor;
        final String amountText;
        if (youPay) {
          chipColor = scheme.errorContainer;
          chipTextColor = scheme.onErrorContainer;
          amountText = formatCurrency(-settlement.amount);
        } else if (youReceive) {
          chipColor = scheme.primaryContainer;
          chipTextColor = scheme.onPrimaryContainer;
          amountText = formatSignedCurrency(settlement.amount);
        } else {
          chipColor = scheme.tertiaryContainer;
          chipTextColor = scheme.onTertiaryContainer;
          amountText = formatCurrency(settlement.amount);
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: Theme.of(context).textTheme.bodyLarge,
                    children: [
                      TextSpan(
                        text: fromName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: verb),
                      TextSpan(
                        text: toName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: chipColor,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        amountText,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: chipTextColor,
                            ),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _showMarkAsPaidDialog(settlement),
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('Mark as Paid'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCompletedSettlementsList() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: _completedSettlements.map((settlement) {
        final date = DateTime.fromMillisecondsSinceEpoch(
          settlement.paidAt ?? DateTime.now().millisecondsSinceEpoch,
        );
        final dateStr = '${date.day}/${date.month}/${date.year}';

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Icon(Icons.check_circle, color: scheme.primary, size: 24),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichText(
                        text: TextSpan(
                          style: Theme.of(context).textTheme.bodyMedium,
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
                      Text(
                        dateStr,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ),
                ),
                Text(
                  formatCurrency(settlement.amount),
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.undo, size: 20),
                  tooltip: 'Undo payment',
                  onPressed: () => _showUndoPaymentDialog(settlement),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Confirms a payment. The amount defaults to the full suggestion and can
  /// be lowered to record a partial payment.
  Future<void> _showMarkAsPaidDialog(Settlement settlement) async {
    final amountController = TextEditingController(
      text: settlement.amount.toStringAsFixed(2),
    );
    final formKey = GlobalKey<FormState>();

    final amount = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm Payment'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: TextSpan(
                  style: Theme.of(dialogContext).textTheme.bodyLarge,
                  children: [
                    TextSpan(
                      text: settlement.fromUserName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const TextSpan(text: ' paid '),
                    TextSpan(
                      text: settlement.toUserName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: amountController,
                decoration: InputDecoration(
                  labelText: 'Amount paid',
                  prefixText: '$currencySymbol ',
                  helperText:
                      'Owed: ${formatCurrency(settlement.amount)} · '
                      'enter less for a partial payment',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                autofocus: true,
                validator: (value) {
                  final paid = double.tryParse(value?.trim() ?? '');
                  if (paid == null || paid <= 0) {
                    return 'Enter an amount greater than 0';
                  }
                  if (paid > settlement.amount + 0.005) {
                    return 'More than the ${formatCurrency(settlement.amount)} owed';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(
                  dialogContext,
                ).pop(double.parse(amountController.text.trim()));
              }
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );

    amountController.dispose();

    if (amount != null) {
      await _markAsPaid(settlement, amount);
    }
  }
}
