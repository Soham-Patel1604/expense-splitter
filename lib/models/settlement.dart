/// Model representing a settlement between two users in a group
class Settlement {
  final String id;
  final String groupId;
  final String fromUserId;
  final String fromUserName;
  final String toUserId;
  final String toUserName;
  final double amount;
  final bool isPaid;
  final int? paidAt;

  Settlement({
    required this.id,
    required this.groupId,
    required this.fromUserId,
    required this.fromUserName,
    required this.toUserId,
    required this.toUserName,
    required this.amount,
    this.isPaid = false,
    this.paidAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'groupId': groupId,
      'fromUserId': fromUserId,
      'toUserId': toUserId,
      'amount': amount,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  factory Settlement.fromMap(Map<String, dynamic> map, String fromName, String toName) {
    return Settlement(
      id: map['id'] as String,
      groupId: map['groupId'] as String,
      fromUserId: map['fromUserId'] as String,
      fromUserName: fromName,
      toUserId: map['toUserId'] as String,
      toUserName: toName,
      amount: (map['amount'] as num).toDouble(),
      isPaid: true, // settlements in database are paid
      paidAt: map['createdAt'] as int?,
    );
  }

  /// Creates a calculated settlement (not yet paid)
  Settlement.calculated({
    required this.fromUserId,
    required this.fromUserName,
    required this.toUserId,
    required this.toUserName,
    required this.amount,
    required this.groupId,
  })  : id = '',
        isPaid = false,
        paidAt = null;

  Settlement copyWith({
    String? id,
    String? groupId,
    String? fromUserId,
    String? fromUserName,
    String? toUserId,
    String? toUserName,
    double? amount,
    bool? isPaid,
    int? paidAt,
  }) {
    return Settlement(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      fromUserId: fromUserId ?? this.fromUserId,
      fromUserName: fromUserName ?? this.fromUserName,
      toUserId: toUserId ?? this.toUserId,
      toUserName: toUserName ?? this.toUserName,
      amount: amount ?? this.amount,
      isPaid: isPaid ?? this.isPaid,
      paidAt: paidAt ?? this.paidAt,
    );
  }
}
