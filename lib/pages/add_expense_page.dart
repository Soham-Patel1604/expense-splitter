import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../models/group_member.dart';
import '../database/database.dart';
import '../repositories/group_repository.dart';
import '../utils/balance_calculator.dart';
import '../utils/currency.dart';

enum SplitType { equal, unequal, percentage }

/// Model for tracking individual consumption in unequal split
class MemberConsumption {
  final String userId;
  final String userName;
  final TextEditingController controller;
  double? amount;

  MemberConsumption({required this.userId, required this.userName})
    : controller = TextEditingController();

  void dispose() {
    controller.dispose();
  }
}

/// Model for tracking individual percentage in percentage split
class MemberPercentage {
  final String userId;
  final String userName;
  final TextEditingController controller;
  double? percentage;

  MemberPercentage({required this.userId, required this.userName})
    : controller = TextEditingController();

  void dispose() {
    controller.dispose();
  }
}

class AddExpensePage extends StatefulWidget {
  final GroupBalanceView groupBalanceView;
  final Expense? existingExpense;

  const AddExpensePage({
    super.key,
    required this.groupBalanceView,
    this.existingExpense,
  });

  @override
  State<AddExpensePage> createState() => _AddExpensePageState();
}

class _AddExpensePageState extends State<AddExpensePage> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _noteController = TextEditingController();

  late GroupRepository _groupRepository;
  List<GroupMember> _members = [];
  String? _selectedPayerId;
  String _selectedCategory = 'other';

  // For equal split
  Set<String> _selectedParticipants = {};

  // For unequal split
  SplitType _splitType = SplitType.equal;
  List<MemberConsumption> _memberConsumptions = [];

  // For percentage split
  List<MemberPercentage> _memberPercentages = [];

  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final database = AppDatabase();
    _groupRepository = GroupRepository(database: database);

    if (widget.existingExpense != null) {
      final exp = widget.existingExpense!;
      _amountController.text = exp.amount.toStringAsFixed(2);
      _descriptionController.text = exp.description ?? '';
      _noteController.text = exp.note ?? '';
      _selectedCategory = exp.category;
      _selectedPayerId = exp.paidByUserId;
      // Every expense stores each person's share, so it reopens in the split
      // it was saved with (the share fields are filled in once members load).
      _splitType = switch (exp.splitType) {
        'unequal' => SplitType.unequal,
        'percentage' => SplitType.percentage,
        _ => SplitType.equal,
      };
      _selectedParticipants = exp.participantIds.toSet();
    }

    _loadGroupMembers();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    _noteController.dispose();
    for (var consumption in _memberConsumptions) {
      consumption.dispose();
    }
    for (var percentage in _memberPercentages) {
      percentage.dispose();
    }
    super.dispose();
  }

  Future<void> _loadGroupMembers() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final members = await _groupRepository.getGroupMembersWithPayments(
        widget.groupBalanceView.group.id,
      );
      final prefs = await SharedPreferences.getInstance();
      final currentUserId = prefs.getString('currentUserId');

      if (!mounted) return;
      setState(() {
        _members = members;
        if (widget.existingExpense != null) {
          final exp = widget.existingExpense!;
          _selectedPayerId = exp.paidByUserId;
          _selectedParticipants = exp.participantIds.toSet();
        } else {
          // Default payer: you (falls back to the first member)
          if (_members.isNotEmpty) {
            _selectedPayerId =
                _members.any((m) => m.userId == currentUserId)
                ? currentUserId
                : _members.first.userId;
          }
          // Default: all members selected as participants for equal split
          _selectedParticipants = _members.map((m) => m.userId).toSet();
        }

        // Initialize consumption controllers for unequal split
        _memberConsumptions = _members
            .map(
              (m) => MemberConsumption(userId: m.userId, userName: m.userName),
            )
            .toList();

        // Initialize percentage controllers for percentage split
        _memberPercentages = _members
            .map(
              (m) => MemberPercentage(userId: m.userId, userName: m.userName),
            )
            .toList();

        _prefillShares();

        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load members: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  /// When editing, fill the unequal / percentage fields from the stored
  /// shares so saving without changes keeps every share exactly as it was.
  void _prefillShares() {
    final exp = widget.existingExpense;
    if (exp == null) return;

    if (_splitType == SplitType.unequal) {
      for (final c in _memberConsumptions) {
        final share = exp.shares[c.userId];
        if (share != null) c.controller.text = share.toStringAsFixed(2);
      }
    } else if (_splitType == SplitType.percentage) {
      final rows = _memberPercentages
          .where((p) => exp.shares.containsKey(p.userId))
          .toList();
      double assigned = 0;
      for (var i = 0; i < rows.length; i++) {
        // The last person gets whatever is left so the fields sum to 100.
        final pct = i == rows.length - 1
            ? 100 - assigned
            : (exp.shares[rows[i].userId]! / exp.amount * 10000).round() / 100;
        assigned += pct;
        rows[i].controller.text = _formatPercent(pct);
      }
    }
  }

  String _formatPercent(double value) {
    final rounded = (value * 100).round() / 100;
    return rounded == rounded.roundToDouble()
        ? rounded.toStringAsFixed(0)
        : rounded.toStringAsFixed(2);
  }

  void _toggleParticipant(String userId) {
    setState(() {
      if (_selectedParticipants.contains(userId)) {
        _selectedParticipants.remove(userId);
      } else {
        _selectedParticipants.add(userId);
      }
    });
  }

  void _selectAllParticipants() {
    setState(() {
      _selectedParticipants = _members.map((m) => m.userId).toSet();
    });
  }

  void _deselectAllParticipants() {
    setState(() {
      _selectedParticipants.clear();
    });
  }

  /// Validate unequal split consumption amounts
  bool _validateUnequalSplit() {
    final totalAmount = double.tryParse(_amountController.text.trim());
    if (totalAmount == null || totalAmount <= 0) {
      return false;
    }

    double enteredSum = 0.0;
    int emptyCount = 0;

    for (var consumption in _memberConsumptions) {
      // Reset first so a value from an earlier attempt can never leak in.
      consumption.amount = null;
      final text = consumption.controller.text.trim();
      if (text.isEmpty) {
        emptyCount++;
        continue;
      }

      final amount = double.tryParse(text);
      if (amount == null || amount < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid amount for ${consumption.userName}')),
        );
        return false;
      }
      // 0 means "had nothing": excluded, and not auto-filled either.
      if (amount > 0) {
        enteredSum += amount;
        consumption.amount = amount;
      }
    }

    // Check if sum exceeds total
    if (enteredSum > totalAmount + 0.01) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Sum of consumption (${formatCurrency(enteredSum)}) exceeds total amount (${formatCurrency(totalAmount)})',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
      return false;
    }

    // If all fields are filled and sum doesn't match exactly
    if (emptyCount == 0 && (enteredSum - totalAmount).abs() > 0.01) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Sum of consumption (${formatCurrency(enteredSum)}) must equal total amount (${formatCurrency(totalAmount)})',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
      return false;
    }

    // Auto-distribute remaining amount to empty fields
    if (emptyCount > 0 && enteredSum < totalAmount) {
      final remaining = totalAmount - enteredSum;
      final sharePerEmpty = remaining / emptyCount;

      for (var consumption in _memberConsumptions) {
        consumption.amount ??= sharePerEmpty;
      }
    }

    return true;
  }

  /// Validates percentage split: ensures positive expense amount and that
  /// percentages sum to 100 (within a 0.01 margin of error)
  bool _validatePercentageSplit() {
    final totalAmount = double.tryParse(_amountController.text.trim());
    if (totalAmount == null || totalAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid expense amount')),
      );
      return false;
    }

    double totalPercent = 0.0;
    for (var item in _memberPercentages) {
      final text = item.controller.text.trim();
      if (text.isNotEmpty) {
        final val = double.tryParse(text);
        if (val == null || val < 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Invalid percentage for ${item.userName}')),
          );
          return false;
        }
        totalPercent += val;
        item.percentage = val;
      } else {
        item.percentage = null;
      }
    }

    if ((totalPercent - 100.0).abs() > 0.01) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Percentages must sum to 100%. Current total: ${totalPercent.toStringAsFixed(1)}%',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
      return false;
    }

    if (!_memberPercentages.any((p) => (p.percentage ?? 0) > 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a percentage for at least one person'),
        ),
      );
      return false;
    }

    return true;
  }

  Future<void> _saveExpense() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_selectedPayerId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select who paid')));
      return;
    }

    // Validation based on split type
    if (_splitType == SplitType.equal) {
      if (_selectedParticipants.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please select at least one participant'),
          ),
        );
        return;
      }
    } else if (_splitType == SplitType.unequal) {
      // Unequal split validation
      if (!_validateUnequalSplit()) {
        return;
      }

      // Check if at least one person has consumption
      final hasConsumption = _memberConsumptions.any(
        (c) => c.amount != null && c.amount! > 0,
      );
      if (!hasConsumption) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter consumption for at least one person'),
          ),
        );
        return;
      }
    } else if (_splitType == SplitType.percentage) {
      // Percentage split validation
      if (!_validatePercentageSplit()) {
        return;
      }
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final amount = double.parse(_amountController.text.trim());
      final description = _descriptionController.text.trim();
      final note = _noteController.text.trim();
      final expenseDescription = description.isEmpty ? 'Expense' : description;
      final expenseNote = note.isEmpty ? null : note;

      // One expense row whatever the split; unequal / percentage carry the
      // exact share of each person, equal is split by the repository.
      final Map<String, double>? shares = switch (_splitType) {
        SplitType.equal => null,
        SplitType.unequal => {
          for (final c in _memberConsumptions)
            if ((c.amount ?? 0) > 0) c.userId: c.amount!,
        },
        SplitType.percentage => splitByPercentages(amount, {
          for (final p in _memberPercentages)
            if ((p.percentage ?? 0) > 0) p.userId: p.percentage!,
        }),
      };
      final participantIds = shares?.keys.toList() ??
          _selectedParticipants.toList();
      final splitType = _splitType.name;

      if (widget.existingExpense != null) {
        await _groupRepository.updateExpense(
          expenseId: widget.existingExpense!.id,
          description: expenseDescription,
          amount: amount,
          paidByUserId: _selectedPayerId!,
          participantIds: participantIds,
          shares: shares,
          category: _selectedCategory,
          note: expenseNote,
          splitType: splitType,
        );
      } else {
        await _groupRepository.addExpense(
          groupId: widget.groupBalanceView.group.id,
          description: expenseDescription,
          amount: amount,
          paidByUserId: _selectedPayerId!,
          participantIds: participantIds,
          shares: shares,
          category: _selectedCategory,
          note: expenseNote,
          splitType: splitType,
        );
      }

      if (mounted) {
        // Show success message
        final isEditing = widget.existingExpense != null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  Icons.check_circle,
                  color: Theme.of(context).colorScheme.onInverseSurface,
                ),
                const SizedBox(width: 8),
                Text(
                  isEditing
                      ? '✓ Expense updated successfully'
                      : '✓ Expense added successfully',
                ),
              ],
            ),
            duration: const Duration(seconds: 2),
          ),
        );

        // Navigate back to settlement page with refresh flag
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: ${e.toString()}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Back arrow only — the Add/Edit title lives in the intro block below
      // (matches create_group / expense_history idiom).
      appBar: AppBar(),
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
                      onPressed: _loadGroupMembers,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Screen title (32) + one friendly helper line (16)
                      Text(
                        widget.existingExpense != null
                            ? 'Edit Expense'
                            : 'Add Expense',
                        style: Theme.of(context).textTheme.displayLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Log what you spent and who shared it, then save.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 24),

                      // Section 1: Expense Details Card
                      _buildExpenseDetailsCard(),
                      const SizedBox(height: 24),

                      // Section 2: Split Type Selector
                      _buildSplitTypeSelector(),
                      const SizedBox(height: 24),

                      // Section 3: Participants/Consumption based on split type
                      if (_splitType == SplitType.equal)
                        _buildEqualSplitSection()
                      else if (_splitType == SplitType.unequal)
                        _buildUnequalSplitSection()
                      else
                        _buildPercentageSplitSection(),
                      const SizedBox(height: 32),

                      // Save Button
                      _buildSaveButton(),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildExpenseDetailsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.receipt_long,
                  color: Theme.of(context).colorScheme.primary,
                  size: 24,
                ),
                const SizedBox(width: 16),
                Text(
                  'Expense Details',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Amount Field
            TextFormField(
              controller: _amountController,
              decoration: InputDecoration(
                labelText: 'Amount *',
                hintText: 'Enter amount',
                prefixText: '$currencySymbol ',
                prefixIcon: const Icon(Icons.payments_outlined),
                // Global InputDecorationTheme handles the field styling.
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Amount is required';
                }
                final amount = double.tryParse(value.trim());
                if (amount == null || amount <= 0) {
                  return 'Please enter a valid amount greater than 0';
                }
                return null;
              },
              enabled: !_isSaving,
            ),
            const SizedBox(height: 16),

            // Description Field
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: 'Description',
                hintText: 'e.g., Food, Cab, Hotel',
                prefixIcon: const Icon(Icons.description),
              ),
              textCapitalization: TextCapitalization.sentences,
              enabled: !_isSaving,
            ),
            const SizedBox(height: 16),

            DropdownButtonFormField<String>(
              initialValue: _selectedCategory,
              decoration: InputDecoration(
                labelText: 'Category',
                prefixIcon: const Icon(Icons.category),
              ),
              items: expenseCategories.entries
                  .map(
                    (entry) => DropdownMenuItem<String>(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: _isSaving
                  ? null
                  : (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _selectedCategory = value;
                      });
                    },
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _noteController,
              decoration: InputDecoration(
                labelText: 'Note (Optional)',
                hintText: 'Any extra details for this expense',
                prefixIcon: const Icon(Icons.sticky_note_2_outlined),
              ),
              textCapitalization: TextCapitalization.sentences,
              enabled: !_isSaving,
              maxLines: 2,
            ),
            const SizedBox(height: 16),

            // Paid By Dropdown
            DropdownButtonFormField<String>(
              initialValue: _selectedPayerId,
              decoration: InputDecoration(
                labelText: 'Paid By *',
                prefixIcon: const Icon(Icons.person),
              ),
              items: _members.map((member) {
                return DropdownMenuItem<String>(
                  value: member.userId,
                  child: Text(member.userName),
                );
              }).toList(),
              onChanged: _isSaving
                  ? null
                  : (value) {
                      setState(() {
                        _selectedPayerId = value;
                      });
                    },
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please select who paid';
                }
                return null;
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSplitTypeSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.splitscreen,
                  color: Theme.of(context).colorScheme.primary,
                  size: 24,
                ),
                const SizedBox(width: 16),
                Text(
                  'Split Type',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 3 Split type options
            Row(
              children: [
                _buildSplitOptionCard(
                  type: SplitType.equal,
                  icon: Icons.pie_chart,
                  title: 'Equal',
                  subtitle: 'Divide equally',
                ),
                const SizedBox(width: 8),
                _buildSplitOptionCard(
                  type: SplitType.unequal,
                  icon: Icons.calculate,
                  title: 'Unequal',
                  subtitle: 'By amount',
                ),
                const SizedBox(width: 8),
                _buildSplitOptionCard(
                  type: SplitType.percentage,
                  icon: Icons.percent,
                  title: 'Percentage',
                  subtitle: 'By % share',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSplitOptionCard({
    required SplitType type,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final isSelected = _splitType == type;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Expanded(
      child: InkWell(
        onTap: _isSaving
            ? null
            : () {
                setState(() {
                  _splitType = type;
                });
              },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.primaryContainer
                : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? scheme.primary : scheme.outlineVariant,
              width: 2,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                color: isSelected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
                size: 28,
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: isSelected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: isSelected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEqualSplitSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.group,
                      color: Theme.of(context).colorScheme.primary,
                      size: 24,
                    ),
                    const SizedBox(width: 16),
                    Text(
                      'Participants',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
                Text(
                  '${_selectedParticipants.length}/${_members.length}',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Quick Actions
            Row(
              children: [
                TextButton.icon(
                  onPressed: _isSaving ? null : _selectAllParticipants,
                  icon: const Icon(Icons.check_box, size: 18),
                  label: const Text('Select All'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _isSaving ? null : _deselectAllParticipants,
                  icon: const Icon(Icons.check_box_outline_blank, size: 18),
                  label: const Text('Clear All'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),

            // Participant List
            ..._members.map((member) {
              final isSelected = _selectedParticipants.contains(member.userId);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: _isSaving
                      ? null
                      : () => _toggleParticipant(member.userId),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.1)
                          : null,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outlineVariant,
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Checkbox(
                          value: isSelected,
                          onChanged: _isSaving
                              ? null
                              : (value) => _toggleParticipant(member.userId),
                          activeColor: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: isSelected
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                          child: Text(
                            member.userName[0].toUpperCase(),
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: isSelected
                                      ? Theme.of(
                                          context,
                                        ).colorScheme.onPrimaryContainer
                                      : Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            member.userName,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(
                                  fontWeight: isSelected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                          ),
                        ),
                        if (isSelected)
                          Icon(
                            Icons.check_circle,
                            color: Theme.of(context).colorScheme.primary,
                            size: 20,
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }),

            // Split Info
            if (_selectedParticipants.isNotEmpty &&
                _amountController.text.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _buildSplitInfoText(),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _buildSplitInfoText() {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) return '';

    final sharePerPerson = amount / _selectedParticipants.length;
    return 'Split equally: ${formatCurrency(sharePerPerson)} per person';
  }

  Widget _buildUnequalSplitSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.receipt_long,
                  color: Theme.of(context).colorScheme.primary,
                  size: 24,
                ),
                const SizedBox(width: 16),
                Text(
                  'Individual Consumption',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Enter amount consumed by each person',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),

            // Consumption list
            ..._memberConsumptions.map((consumption) {
              final hasValue = consumption.controller.text.trim().isNotEmpty;
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: hasValue
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                      child: Text(
                        consumption.userName[0].toUpperCase(),
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: hasValue
                              ? Theme.of(context).colorScheme.onPrimaryContainer
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            consumption.userName,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 120,
                      child: TextFormField(
                        controller: consumption.controller,
                        decoration: InputDecoration(
                          hintText: 'Amount',
                          prefixText: '$currencySymbol ',
                          isDense: true,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        enabled: !_isSaving,
                        onChanged: (value) {
                          setState(
                            () {},
                          ); // Refresh to update validation messages
                        },
                      ),
                    ),
                  ],
                ),
              );
            }),

            // Validation info
            const SizedBox(height: 16),
            _buildConsumptionSummary(),
          ],
        ),
      ),
    );
  }

  Widget _buildConsumptionSummary() {
    final totalAmount = double.tryParse(_amountController.text.trim());
    if (totalAmount == null || totalAmount <= 0) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Theme.of(context).colorScheme.tertiary),
        ),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              color: Theme.of(context).colorScheme.onTertiaryContainer,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Enter total amount first to see consumption summary',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ),
      );
    }

    double enteredSum = 0.0;
    int emptyCount = 0;

    for (var consumption in _memberConsumptions) {
      final text = consumption.controller.text.trim();
      if (text.isNotEmpty) {
        final amount = double.tryParse(text);
        if (amount != null && amount > 0) {
          enteredSum += amount;
        }
      } else {
        emptyCount++;
      }
    }

    final remaining = totalAmount - enteredSum;
    Color bgColor;
    Color borderColor;
    Color textColor;
    IconData icon;
    String message;

    if (enteredSum > totalAmount + 0.01) {
      // Exceeds total
      bgColor = Theme.of(context).colorScheme.errorContainer;
      borderColor = Theme.of(context).colorScheme.error;
      textColor = Theme.of(context).colorScheme.onErrorContainer;
      icon = Icons.error_outline;
      message =
          'Entered: ${formatCurrency(enteredSum)} | Exceeds total by ${formatCurrency(enteredSum - totalAmount)}';
    } else if (emptyCount == 0 && (enteredSum - totalAmount).abs() > 0.01) {
      // All filled but doesn't match
      bgColor = Theme.of(context).colorScheme.tertiaryContainer;
      borderColor = Theme.of(context).colorScheme.tertiary;
      textColor = Theme.of(context).colorScheme.onTertiaryContainer;
      icon = Icons.warning_amber;
      message =
          'Entered: ${formatCurrency(enteredSum)} | Missing: ${formatCurrency(remaining)}';
    } else if (emptyCount > 0 && remaining > 0) {
      // Will auto-distribute
      final autoShare = remaining / emptyCount;
      bgColor = Theme.of(context).colorScheme.secondaryContainer;
      borderColor = Theme.of(context).colorScheme.secondary;
      textColor = Theme.of(context).colorScheme.onSecondaryContainer;
      icon = Icons.auto_fix_high;
      message =
          'Entered: ${formatCurrency(enteredSum)} | Remaining ${formatCurrency(remaining)} will be split among $emptyCount member${emptyCount > 1 ? 's' : ''} (${formatCurrency(autoShare)} each)';
    } else {
      // Perfect match
      bgColor = Theme.of(context).colorScheme.primaryContainer;
      borderColor = Theme.of(context).colorScheme.primary;
      textColor = Theme.of(context).colorScheme.onPrimaryContainer;
      icon = Icons.check_circle_outline;
      message = 'Perfect! Total consumption matches expense amount';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: textColor, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: textColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPercentageSplitSection() {
    final totalAmount = double.tryParse(_amountController.text.trim()) ?? 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.percent,
                  color: Theme.of(context).colorScheme.primary,
                  size: 24,
                ),
                const SizedBox(width: 16),
                Text(
                  'Percentage Split',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Enter percentage for each person (must sum to 100%)',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),

            // Members Percentage inputs
            ..._memberPercentages.map((item) {
              final pct = double.tryParse(item.controller.text.trim()) ?? 0.0;
              final calculatedShare = totalAmount > 0
                  ? (totalAmount * pct / 100.0)
                  : 0.0;
              final hasValue = item.controller.text.trim().isNotEmpty;

              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: hasValue
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                      child: Text(
                        item.userName[0].toUpperCase(),
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: hasValue
                              ? Theme.of(context).colorScheme.onPrimaryContainer
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.userName,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          if (totalAmount > 0 && pct > 0)
                            Text(
                              '≈ ${formatCurrency(calculatedShare)}',
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 110,
                      child: TextFormField(
                        controller: item.controller,
                        decoration: InputDecoration(
                          hintText: '0',
                          suffixText: '%',
                          isDense: true,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        enabled: !_isSaving,
                        onChanged: (value) {
                          setState(
                            () {},
                          ); // Refresh calculated shares and summary
                        },
                      ),
                    ),
                  ],
                ),
              );
            }),

            const SizedBox(height: 16),
            _buildPercentageSummary(),
          ],
        ),
      ),
    );
  }

  Widget _buildPercentageSummary() {
    double totalPercent = 0.0;
    int enteredCount = 0;

    for (var item in _memberPercentages) {
      final text = item.controller.text.trim();
      if (text.isNotEmpty) {
        final val = double.tryParse(text);
        if (val != null) {
          totalPercent += val;
          enteredCount++;
        }
      }
    }

    final diff = 100.0 - totalPercent;
    Color bgColor;
    Color borderColor;
    Color textColor;
    IconData icon;
    String message;

    if (totalPercent > 100.01) {
      bgColor = Theme.of(context).colorScheme.errorContainer;
      borderColor = Theme.of(context).colorScheme.error;
      textColor = Theme.of(context).colorScheme.onErrorContainer;
      icon = Icons.error_outline;
      message =
          'Total: ${totalPercent.toStringAsFixed(1)}% | Exceeds 100% by ${(totalPercent - 100).toStringAsFixed(1)}%';
    } else if (diff.abs() <= 0.01 && enteredCount > 0) {
      bgColor = Theme.of(context).colorScheme.primaryContainer;
      borderColor = Theme.of(context).colorScheme.primary;
      textColor = Theme.of(context).colorScheme.onPrimaryContainer;
      icon = Icons.check_circle_outline;
      message = 'Total: 100% — Exact match!';
    } else {
      bgColor = Theme.of(context).colorScheme.tertiaryContainer;
      borderColor = Theme.of(context).colorScheme.tertiary;
      textColor = Theme.of(context).colorScheme.onTertiaryContainer;
      icon = Icons.warning_amber;
      message =
          'Total: ${totalPercent.toStringAsFixed(1)}% | Remaining: ${diff.toStringAsFixed(1)}%';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(icon, color: textColor, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: textColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: _isSaving ? null : _saveExpense,
        icon: _isSaving
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onPrimary,
                ),
              )
            : const Icon(Icons.save),
        label: Text(
          _isSaving
              ? 'Saving...'
              : (widget.existingExpense != null
                    ? 'Update Expense'
                    : 'Save Expense'),
        ),
        // Theme supplies primary/onPrimary + radius 16; only the disabled
        // colours are tinted so the onPrimary spinner stays legible while saving.
        style: ElevatedButton.styleFrom(
          disabledBackgroundColor: scheme.primary.withValues(alpha: 0.6),
          disabledForegroundColor: scheme.onPrimary,
        ),
      ),
    );
  }
}
