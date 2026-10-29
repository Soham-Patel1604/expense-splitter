/// Model representing a single expense in a group
class Expense {
  final String id;
  final String groupId;
  final String? description;
  final String category;
  final String? note;
  final String splitType;
  final double amount;
  final String paidByUserId;
  final String paidByUserName;
  final List<String> participantIds;
  final List<String> participantNames;

  /// What each participant owes for this expense, keyed by user ID.
  /// Always sums to [amount].
  final Map<String, double> shares;
  final int createdAt;

  Expense({
    required this.id,
    required this.groupId,
    this.description,
    this.category = 'other',
    this.note,
    this.splitType = 'equal',
    required this.amount,
    required this.paidByUserId,
    required this.paidByUserName,
    required this.participantIds,
    required this.participantNames,
    required this.shares,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'groupId': groupId,
      'paidByUserId': paidByUserId,
      'amount': amount,
      'description': description,
      'category': category,
      'note': note,
      'splitType': splitType,
      'createdAt': createdAt,
    };
  }

  factory Expense.fromMap(
    Map<String, dynamic> map,
    String paidByName,
    List<String> participantIds,
    List<String> participantNames,
    Map<String, double> shares,
  ) {
    return Expense(
      id: map['id'] as String,
      groupId: map['groupId'] as String,
      description: map['description'] as String?,
      category: (map['category'] as String?) ?? 'other',
      note: map['note'] as String?,
      splitType: (map['splitType'] as String?) ?? 'equal',
      amount: (map['amount'] as num).toDouble(),
      paidByUserId: map['paidByUserId'] as String,
      paidByUserName: paidByName,
      participantIds: participantIds,
      participantNames: participantNames,
      shares: shares,
      createdAt: map['createdAt'] as int,
    );
  }

  /// What [userId] owes for this expense (0 if they did not take part).
  double shareOf(String userId) => shares[userId] ?? 0.0;

  Expense copyWith({
    String? id,
    String? groupId,
    String? description,
    String? category,
    String? note,
    String? splitType,
    double? amount,
    String? paidByUserId,
    String? paidByUserName,
    List<String>? participantIds,
    List<String>? participantNames,
    Map<String, double>? shares,
    int? createdAt,
  }) {
    return Expense(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      description: description ?? this.description,
      category: category ?? this.category,
      note: note ?? this.note,
      splitType: splitType ?? this.splitType,
      amount: amount ?? this.amount,
      paidByUserId: paidByUserId ?? this.paidByUserId,
      paidByUserName: paidByUserName ?? this.paidByUserName,
      participantIds: participantIds ?? this.participantIds,
      participantNames: participantNames ?? this.participantNames,
      shares: shares ?? this.shares,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// Category labels used for the enhanced add-expense and stats UI.
const Map<String, String> expenseCategories = {
  'food': 'Food and Drinks',
  'transport': 'Transport',
  'accommodation': 'Accommodation',
  'entertainment': 'Entertainment',
  'groceries': 'Groceries',
  'utilities': 'Utilities',
  'shopping': 'Shopping',
  'health': 'Health',
  'other': 'Other',
};

class MemberExpenseStats {
  final String userId;
  final String userName;
  final double amountPaid;
  final double amountOwed;

  /// Paid minus owed, adjusted for settlements already marked as paid —
  /// the same number the Settle tab works from.
  final double netBalance;

  MemberExpenseStats({
    required this.userId,
    required this.userName,
    required this.amountPaid,
    required this.amountOwed,
    required this.netBalance,
  });
}

class GroupExpenseStats {
  final int expenseCount;
  final double totalAmount;
  final Map<String, double> categoryTotals;
  final List<MemberExpenseStats> memberStats;

  GroupExpenseStats({
    required this.expenseCount,
    required this.totalAmount,
    required this.categoryTotals,
    required this.memberStats,
  });

  bool get hasData => expenseCount > 0;

  double get averageExpense {
    if (expenseCount == 0) {
      return 0.0;
    }
    return totalAmount / expenseCount;
  }
}
