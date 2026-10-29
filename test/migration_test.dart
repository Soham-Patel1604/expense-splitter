import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:expense_splitter/database/database.dart';
import 'package:expense_splitter/repositories/group_repository.dart';

/// The v4 schema exactly as v1.0.0 created it.
Future<void> _createV4(Database db, int version) async {
  await db.execute('CREATE TABLE users(id TEXT PRIMARY KEY, name TEXT NOT NULL, '
      'phone TEXT, createdAt INTEGER NOT NULL)');
  await db.execute('CREATE TABLE groups(id TEXT PRIMARY KEY, name TEXT NOT NULL, '
      'description TEXT, createdAt INTEGER NOT NULL, createdBy TEXT NOT NULL)');
  await db.execute('CREATE TABLE group_members(id TEXT PRIMARY KEY, '
      'groupId TEXT NOT NULL, userId TEXT NOT NULL, UNIQUE(groupId, userId))');
  await db.execute('CREATE TABLE expenses(id TEXT PRIMARY KEY, groupId TEXT NOT NULL, '
      'paidByUserId TEXT NOT NULL, amount REAL NOT NULL, description TEXT, '
      "category TEXT NOT NULL DEFAULT 'other', note TEXT, "
      "splitType TEXT NOT NULL DEFAULT 'equal', createdAt INTEGER NOT NULL)");
  await db.execute('CREATE TABLE expense_splits(id TEXT PRIMARY KEY, '
      'groupId TEXT NOT NULL, fromUserId TEXT NOT NULL, toUserId TEXT NOT NULL, '
      'amount REAL NOT NULL, description TEXT, createdAt INTEGER NOT NULL)');
  await db.execute('CREATE TABLE settlements(id TEXT PRIMARY KEY, '
      'groupId TEXT NOT NULL, fromUserId TEXT NOT NULL, toUserId TEXT NOT NULL, '
      'amount REAL NOT NULL, createdAt INTEGER NOT NULL)');
  await db.execute('CREATE TABLE expense_participants(expenseId TEXT NOT NULL, '
      'userId TEXT NOT NULL, PRIMARY KEY (expenseId, userId))');
}

void main() {
  test('v4 -> v5 keeps the data and fixes the money', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final tempDir = Directory.systemTemp.createTempSync('migration_test');
    await databaseFactory.setDatabasesPath(tempDir.path);
    final path = join(tempDir.path, 'expense_splitter.db');

    // 1. A v1.0.0 database: an "Initial payment" with no participants, and
    //    an unequal split stored as one row per person.
    final v4 = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(version: 4, onCreate: _createV4));
    for (final u in ['me', 'soham']) {
      await v4.insert('users', {'id': u, 'name': u, 'createdAt': 0});
    }
    await v4.insert('groups',
        {'id': 'g', 'name': 'Goa', 'createdAt': 0, 'createdBy': 'me'});
    for (final u in ['me', 'soham']) {
      await v4.insert('group_members', {'id': 'g-$u', 'groupId': 'g', 'userId': u});
    }
    await v4.insert('expenses', {'id': 'initial', 'groupId': 'g',
        'paidByUserId': 'soham', 'amount': 500.0,
        'description': 'Initial payment', 'createdAt': 1});
    for (final (id, who) in [('dinner-me', 'me'), ('dinner-soham', 'soham')]) {
      await v4.insert('expenses', {'id': id, 'groupId': 'g',
          'paidByUserId': 'soham', 'amount': 250.0, 'splitType': 'unequal',
          'description': 'Dinner - $who', 'createdAt': 2});
      await v4.insert('expense_participants', {'expenseId': id, 'userId': who});
    }
    await v4.close();

    // 2. Open with the current app code -> runs the v5 upgrade.
    final appDb = AppDatabase();
    final db = await appDb.database;
    final repo = GroupRepository(database: appDb);

    expect(await db.getVersion(), AppDatabase.schemaVersion);
    final columns = await db.rawQuery('PRAGMA table_info(expense_participants)');
    expect(columns.map((c) => c['name']), contains('shareAmount'));
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='expense_splits'");
    expect(tables, isEmpty);

    // 3. The initial payment is now shared by both members.
    final initial = (await repo.getGroupExpenses('g'))
        .firstWhere((e) => e.id == 'initial');
    expect(initial.shares, {'me': 250, 'soham': 250});

    // 4. Soham paid 500 up front + 500 dinner; my share is 250 + 250.
    final pending = await repo.calculatePendingSettlements('g');
    expect(pending, hasLength(1));
    expect(pending.single.fromUserId, 'me');
    expect(pending.single.toUserId, 'soham');
    expect(pending.single.amount, 500);
    expect(await repo.getUserNetBalanceForGroup('g', 'me'), -500);

    await appDb.close();
    tempDir.deleteSync(recursive: true);
  });
}
