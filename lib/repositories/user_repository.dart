import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../database/database.dart';
import '../models/user.dart';

/// Trims and collapses inner whitespace: "  Soham   Patel " -> "Soham Patel".
String normalizeName(String name) => name.trim().split(RegExp(r'\s+')).join(' ');

/// Empty or whitespace-only phone numbers are treated as "no phone".
String? normalizePhone(String? phone) {
  final trimmed = phone?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Finds the person with this name (case-insensitive) or creates them.
///
/// People are identified by name on this device, so logging in as "Soham"
/// again — or adding "soham" to another event — reaches the same events.
/// A phone number only tells two same-named people apart: a different phone
/// means a different person, while a match without a phone gets it filled in.
Future<({String id, bool existed})> findOrCreateUser(
  DatabaseExecutor executor, {
  required String name,
  String? phone,
}) async {
  final cleanName = normalizeName(name);
  final cleanPhone = normalizePhone(phone);
  if (cleanName.isEmpty) {
    throw ArgumentError('Name cannot be empty');
  }

  final candidates = await executor.query(
    'users',
    where: 'LOWER(TRIM(name)) = LOWER(?)',
    whereArgs: [cleanName],
    orderBy: 'createdAt ASC',
  );

  Map<String, Object?>? match;
  if (cleanPhone == null) {
    // Prefer a profile without a phone, otherwise the oldest one.
    if (candidates.isNotEmpty) {
      match = candidates.firstWhere(
        (row) => normalizePhone(row['phone'] as String?) == null,
        orElse: () => candidates.first,
      );
    }
  } else {
    for (final row in candidates) {
      if (normalizePhone(row['phone'] as String?) == cleanPhone) {
        match = row;
        break;
      }
    }
    if (match == null) {
      for (final row in candidates) {
        if (normalizePhone(row['phone'] as String?) == null) {
          match = row;
          await executor.update(
            'users',
            {'phone': cleanPhone},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
          break;
        }
      }
    }
  }

  if (match != null) {
    return (id: match['id'] as String, existed: true);
  }

  final userId = const Uuid().v4();
  await executor.insert('users', {
    'id': userId,
    'name': cleanName,
    'phone': cleanPhone,
    'createdAt': DateTime.now().millisecondsSinceEpoch,
  });
  return (id: userId, existed: false);
}

class UserRepository {
  final AppDatabase _database;

  UserRepository({required AppDatabase database}) : _database = database;

  /// Signs in with a name (and optional phone): reuses the existing profile
  /// so all its events come back, or creates a new one.
  Future<({String id, bool existed})> loginOrCreate(
    String name,
    String? phone,
  ) async {
    final db = await _database.database;
    return db.transaction(
      (txn) => findOrCreateUser(txn, name: name, phone: phone),
    );
  }

  /// Retrieves a user by ID
  Future<User?> getUserById(String userId) async {
    final db = await _database.database;

    final result = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
    );

    if (result.isEmpty) {
      return null;
    }

    return User.fromMap(result.first);
  }

  /// True when another profile already uses [name] (case-insensitive).
  Future<bool> isNameTaken(String name, {required String excludingUserId}) async {
    final db = await _database.database;
    final result = await db.query(
      'users',
      columns: ['id'],
      where: 'LOWER(TRIM(name)) = LOWER(?) AND id != ?',
      whereArgs: [normalizeName(name), excludingUserId],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  /// Updates a user
  Future<void> updateUser(User user) async {
    final db = await _database.database;

    await db.update(
      'users',
      user.copyWith(name: normalizeName(user.name)).toMap(),
      where: 'id = ?',
      whereArgs: [user.id],
    );
  }

  /// Folds duplicate rows for the same person into one, so a name reaches all
  /// of its events. Earlier versions created a new row on every login and for
  /// every phoneless friend in every event.
  ///
  /// Rows are merged only when they share a name (case-insensitive), their
  /// phones don't conflict, and they are never in the same event — two
  /// same-named people inside one event are left alone, since merging them
  /// would change that event's numbers. [preferredUserId] (the signed-in
  /// profile) is kept when it is part of a merge.
  ///
  /// Returns a map of removed user ID -> the ID it was merged into.
  Future<Map<String, String>> mergeDuplicateUsers({
    String? preferredUserId,
  }) async {
    final db = await _database.database;
    final merged = <String, String>{};

    await db.transaction((txn) async {
      final users = await txn.query('users', orderBy: 'createdAt ASC');
      final memberships = await txn.query('group_members');

      final groupsOf = <String, Set<String>>{};
      for (final row in memberships) {
        groupsOf
            .putIfAbsent(row['userId'] as String, () => <String>{})
            .add(row['groupId'] as String);
      }

      final byName = <String, List<Map<String, Object?>>>{};
      for (final user in users) {
        final key = normalizeName(user['name'] as String).toLowerCase();
        byName.putIfAbsent(key, () => []).add(user);
      }

      for (final sameName in byName.values) {
        if (sameName.length < 2) continue;

        final phones = sameName
            .map((u) => normalizePhone(u['phone'] as String?))
            .whereType<String>()
            .toSet();

        // Clusters that may be one person: everyone when at most one phone is
        // in play; otherwise only rows sharing the exact same phone.
        final clusters = phones.length <= 1
            ? [sameName]
            : phones
                  .map(
                    (p) => sameName
                        .where(
                          (u) => normalizePhone(u['phone'] as String?) == p,
                        )
                        .toList(),
                  )
                  .toList();

        for (final cluster in clusters) {
          if (cluster.length < 2) continue;

          final keeper = cluster.firstWhere(
            (u) => u['id'] == preferredUserId,
            orElse: () => cluster.first,
          );
          final keeperId = keeper['id'] as String;
          final keeperGroups = {...?groupsOf[keeperId]};
          String? keeperPhone = normalizePhone(keeper['phone'] as String?);

          for (final dup in cluster) {
            final dupId = dup['id'] as String;
            if (dupId == keeperId) continue;

            final dupGroups = groupsOf[dupId] ?? <String>{};
            if (dupGroups.any(keeperGroups.contains)) continue;

            await _reassignUser(txn, from: dupId, to: keeperId);
            keeperGroups.addAll(dupGroups);
            keeperPhone ??= normalizePhone(dup['phone'] as String?);
            merged[dupId] = keeperId;
          }

          if (keeperPhone != normalizePhone(keeper['phone'] as String?)) {
            await txn.update(
              'users',
              {'phone': keeperPhone},
              where: 'id = ?',
              whereArgs: [keeperId],
            );
          }
        }
      }
    });

    return merged;
  }

  /// Points every reference to user [from] at user [to], then deletes [from].
  Future<void> _reassignUser(
    Transaction txn, {
    required String from,
    required String to,
  }) async {
    const references = {
      'group_members': ['userId'],
      'expenses': ['paidByUserId'],
      'expense_participants': ['userId'],
      'settlements': ['fromUserId', 'toUserId'],
      'groups': ['createdBy'],
    };
    for (final entry in references.entries) {
      for (final column in entry.value) {
        await txn.update(
          entry.key,
          {column: to},
          where: '$column = ?',
          whereArgs: [from],
        );
      }
    }
    await txn.delete('users', where: 'id = ?', whereArgs: [from]);
  }
}
