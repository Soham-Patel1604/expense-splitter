class Group {
  final String id;
  final String name;
  final String? description;
  final int createdAt;
  final String createdBy;

  Group({
    required this.id,
    required this.name,
    this.description,
    required this.createdAt,
    required this.createdBy,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'createdAt': createdAt,
      'createdBy': createdBy,
    };
  }

  factory Group.fromMap(Map<String, dynamic> map) {
    return Group(
      id: map['id'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      createdAt: map['createdAt'] as int,
      createdBy: map['createdBy'] as String,
    );
  }
}

class GroupBalanceView {
  final Group group;

  /// The current user's net position in this group:
  /// positive = others owe you, negative = you owe others.
  final double netBalance;

  GroupBalanceView({
    required this.group,
    required this.netBalance,
  });
}
