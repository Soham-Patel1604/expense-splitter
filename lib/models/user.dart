class User {
  final String id;
  final String name;
  final String? phone;
  final int createdAt;

  User({
    required this.id,
    required this.name,
    this.phone,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'phone': phone,
      'createdAt': createdAt,
    };
  }

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'] as String,
      name: map['name'] as String,
      phone: map['phone'] as String?,
      createdAt: map['createdAt'] as int,
    );
  }

  User copyWith({String? id, String? name, String? phone, int? createdAt}) {
    return User(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
