import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:expense_splitter/database/database.dart';
import 'package:expense_splitter/models/friend_input.dart';
import 'package:expense_splitter/repositories/group_repository.dart';
import 'package:expense_splitter/repositories/user_repository.dart';

const _payer = 'user-payer';
const _alice = 'user-alice';
const _bob = 'user-bob';
const _groupId = 'group-1';
const _childTables = ['group_members', 'expenses', 'expense_participants',
    'settlements'];

Future<List<String>> participantsOf(Database db, String expenseId) async {
  final rows = await db.query('expense_participants',
      where: 'expenseId = ?', whereArgs: [expenseId]);
  return rows.map((r) => r['userId'] as String).toList()..sort();
}

Future<String> onlyExpenseId(Database db) async {
  final rows = await db.query('expenses');
  expect(rows, hasLength(1));
  return rows.first['id'] as String;
}

void main() {
  late Directory tempDir;
  late AppDatabase appDb;
  late GroupRepository repo;
  late UserRepository users;
  late Database db;

  setUpAll(() => tempDir = Directory.systemTemp.createTempSync('split_money_test'));

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath(tempDir.path);
    appDb = AppDatabase();
    repo = GroupRepository(database: appDb);
    users = UserRepository(database: appDb);
    db = await appDb.database;
    for (final t in ['expense_participants', 'expenses', 'settlements',
        'group_members', 'groups', 'users']) {
      await db.delete(t);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final u in [_payer, _alice, _bob]) {
      await db.insert('users', {'id': u, 'name': u, 'createdAt': now});
    }
    await db.insert('groups',
        {'id': _groupId, 'name': 'Trip', 'createdAt': now, 'createdBy': _payer});
    for (final u in [_payer, _alice, _bob]) {
      await db.insert('group_members',
          {'id': '$_groupId-$u', 'groupId': _groupId, 'userId': u});
    }
  });

  tearDownAll(() async {
    await appDb.close();
    tempDir.deleteSync(recursive: true);
  });

  test('foreign keys are enforced', () async {
    await expectLater(
      db.insert('group_members',
          {'id': 'x', 'groupId': 'no-such-group', 'userId': _alice}),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('addExpense -> updateExpense round-trips participants and amount', () async {
    await repo.addExpense(groupId: _groupId, description: 'Dinner', amount: 500.0,
        paidByUserId: _payer, participantIds: [_alice], splitType: 'unequal');
    final id = await onlyExpenseId(db);
    expect(await participantsOf(db, id), [_alice]);

    // No-op edit (the F1 scenario): participants come back exactly as passed,
    // never silently widened to every group member.
    await repo.updateExpense(expenseId: id, description: 'Dinner (edited)',
        amount: 475.5, paidByUserId: _payer, participantIds: [_alice], splitType: 'equal');
    expect(await participantsOf(db, id), [_alice]);
    final updated = await db.query('expenses', where: 'id = ?', whereArgs: [id]);
    expect(updated, hasLength(1));
    expect((updated.first['amount'] as num).toDouble(), 475.5);

    // A deliberate change comes back exactly as written too.
    await repo.updateExpense(expenseId: id, description: 'Dinner (edited)',
        amount: 475.5, paidByUserId: _payer, participantIds: [_alice, _bob],
        splitType: 'equal');
    expect(await participantsOf(db, id), [_alice, _bob]);
    expect(await db.query('expenses'), hasLength(1));
  });

  test('deleteExpense removes the expense row and its participant rows', () async {
    await repo.addExpense(groupId: _groupId, description: 'Cab', amount: 120.0,
        paidByUserId: _payer, participantIds: [_alice, _bob]);
    final id = await onlyExpenseId(db);
    expect(await db.query('expense_participants',
        where: 'expenseId = ?', whereArgs: [id]), hasLength(2));

    await repo.deleteExpense(id);

    expect(await db.query('expenses', where: 'id = ?', whereArgs: [id]), isEmpty);
    expect(await db.query('expense_participants',
        where: 'expenseId = ?', whereArgs: [id]), isEmpty);
  });

  test('deleteGroup empties every child table', () async {
    await repo.addExpense(groupId: _groupId, description: 'Dinner', amount: 500.0,
        paidByUserId: _payer, participantIds: [_alice], splitType: 'unequal');
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('settlements', {'id': 'settle-1', 'groupId': _groupId,
        'fromUserId': _alice, 'toUserId': _payer, 'amount': 50.0, 'createdAt': now});

    await repo.deleteGroup(_groupId);

    for (final table in _childTables) {
      expect(await db.query(table), isEmpty,
          reason: '$table must be empty after deleteGroup');
    }
  });

  group('balances (bugs #5 / #6)', () {
    test('unequal split: the payer is credited and the debt shows up', () async {
      // Payer paid 500: Alice had 250, the payer 250.
      await repo.addExpense(groupId: _groupId, description: 'Dinner',
          amount: 500, paidByUserId: _payer, participantIds: [_alice, _payer],
          shares: {_alice: 250, _payer: 250}, splitType: 'unequal');

      final pending = await repo.calculatePendingSettlements(_groupId);
      expect(pending, hasLength(1));
      expect(pending.single.fromUserId, _alice);
      expect(pending.single.toUserId, _payer);
      expect(pending.single.amount, 250);

      // The Events screen uses the same numbers.
      expect(await repo.getUserNetBalanceForGroup(_groupId, _alice), -250);
      expect(await repo.getUserNetBalanceForGroup(_groupId, _payer), 250);
      final home = await repo.getGroupsWithBalance(_alice);
      expect(home.single.netBalance, -250);
    });

    test('payer who is not a participant is still owed the money', () async {
      await repo.addExpense(groupId: _groupId, description: 'Gift',
          amount: 300, paidByUserId: _payer, participantIds: [_alice, _bob]);

      final balances = await repo.getGroupBalances(_groupId);
      expect(balances, {_payer: 300, _alice: -150, _bob: -150});
    });

    test('mark as paid settles to zero, never flips the sign', () async {
      await repo.addExpense(groupId: _groupId, description: 'Dinner',
          amount: 500, paidByUserId: _payer, participantIds: [_alice, _payer]);
      final pending = await repo.calculatePendingSettlements(_groupId);

      await repo.markSettlementAsPaid(pending.single);

      expect(await repo.calculatePendingSettlements(_groupId), isEmpty);
      expect(await repo.getUserNetBalanceForGroup(_groupId, _alice), 0);
      expect(await repo.getUserNetBalanceForGroup(_groupId, _payer), 0);
    });

    test('partial payment leaves the rest pending, undo restores it', () async {
      await repo.addExpense(groupId: _groupId, description: 'Dinner',
          amount: 500, paidByUserId: _payer, participantIds: [_alice, _payer]);
      final pending = await repo.calculatePendingSettlements(_groupId);

      final paymentId =
          await repo.markSettlementAsPaid(pending.single, amount: 100);
      final afterPartial = await repo.calculatePendingSettlements(_groupId);
      expect(afterPartial.single.amount, 150);

      await repo.deleteSettlement(paymentId);
      final afterUndo = await repo.calculatePendingSettlements(_groupId);
      expect(afterUndo.single.amount, 250);
    });

    test('insights net position matches the Settle tab after a payment', () async {
      await repo.addExpense(groupId: _groupId, description: 'Dinner',
          amount: 300, paidByUserId: _payer,
          participantIds: [_payer, _alice, _bob]);
      final pending = await repo.calculatePendingSettlements(_groupId);
      await repo.markSettlementAsPaid(
          pending.firstWhere((s) => s.fromUserId == _alice));

      final stats = await repo.getGroupExpenseStats(_groupId);
      final net = {for (final m in stats.memberStats) m.userId: m.netBalance};
      expect(net, {_payer: 100, _alice: 0, _bob: -100});
      expect(stats.expenseCount, 1);
      expect(stats.totalAmount, 300);
    });

    test('equal split of an odd amount adds up to the paisa', () async {
      await repo.addExpense(groupId: _groupId, description: 'Snacks',
          amount: 100, paidByUserId: _payer,
          participantIds: [_payer, _alice, _bob]);

      final expense = (await repo.getGroupExpenses(_groupId)).single;
      final total = expense.shares.values.fold<double>(0, (a, b) => a + b);
      expect(total, closeTo(100, 1e-9));
      expect(expense.shares.values.toList()..sort(), [33.33, 33.33, 33.34]);
    });

    test('editing an expense into an unequal split stores real shares', () async {
      await repo.addExpense(groupId: _groupId, description: 'Hotel',
          amount: 300, paidByUserId: _payer, participantIds: [_alice, _bob]);
      final id = await onlyExpenseId(db);

      await repo.updateExpense(expenseId: id, description: 'Hotel',
          amount: 300, paidByUserId: _payer, participantIds: [_alice, _bob],
          shares: {_alice: 100, _bob: 200}, splitType: 'unequal');

      final expense = (await repo.getGroupExpenses(_groupId)).single;
      expect(expense.splitType, 'unequal');
      expect(expense.shares, {_alice: 100, _bob: 200});
      expect(await repo.getUserNetBalanceForGroup(_groupId, _bob), -200);
    });

    test('shares that do not add up are rejected', () async {
      await expectLater(
        repo.addExpense(groupId: _groupId, description: 'Bad', amount: 300,
            paidByUserId: _payer, participantIds: [_alice],
            shares: {_alice: 100}),
        throwsArgumentError,
      );
      expect(await db.query('expenses'), isEmpty);
    });
  });

  group('events and identity (bug #3)', () {
    test('initial payment is split among every member', () async {
      final login = await users.loginOrCreate('Soham', null);
      await repo.createGroupWithMembers(
        name: 'Goa',
        currentUserId: login.id,
        friends: [FriendInput(name: 'Deval', amountPaid: 500)],
      );

      final group = (await repo.getAllGroupsForUser(login.id)).single;
      final pending = await repo.calculatePendingSettlements(group.id);
      expect(pending, hasLength(1));
      expect(pending.single.fromUserName, 'Soham');
      expect(pending.single.toUserName, 'Deval');
      expect(pending.single.amount, 250);
    });

    test('logging in again with the same name brings the events back', () async {
      final first = await users.loginOrCreate('Soham', null);
      await repo.createGroupWithMembers(
          name: 'Goa', currentUserId: first.id, friends: []);

      final again = await users.loginOrCreate('  soham ', null);
      expect(again.existed, isTrue);
      expect(again.id, first.id);
      expect(await repo.getAllGroupsForUser(again.id), hasLength(1));
    });

    test('a friend without a phone is the same person in every event', () async {
      final me = await users.loginOrCreate('Soham', null);
      await repo.createGroupWithMembers(name: 'Goa', currentUserId: me.id,
          friends: [FriendInput(name: 'Deval')]);
      await repo.createGroupWithMembers(name: 'Manali', currentUserId: me.id,
          friends: [FriendInput(name: 'deval')]);

      final deval = await users.loginOrCreate('Deval', null);
      expect(deval.existed, isTrue);
      expect(await repo.getAllGroupsForUser(deval.id), hasLength(2));
    });

    test('a different phone number means a different person', () async {
      final a = await users.loginOrCreate('Rahul', '111');
      final b = await users.loginOrCreate('Rahul', '222');
      expect(b.id, isNot(a.id));
      expect(b.existed, isFalse);
    });

    test('adding the same person twice to one event is refused', () async {
      final me = await users.loginOrCreate('Soham', null);
      await expectLater(
        repo.createGroupWithMembers(name: 'Goa', currentUserId: me.id,
            friends: [FriendInput(name: 'soham')]),
        throwsException,
      );
      expect(await repo.getAllGroupsForUser(me.id), isEmpty);
    });

    test('duplicate profiles from older versions are merged', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      // Two "Soham" rows (one per old login), each in its own event.
      await db.insert('users', {'id': 'old-soham', 'name': 'Soham', 'createdAt': now});
      await db.insert('users', {'id': 'new-soham', 'name': 'soham', 'createdAt': now + 1});
      for (final (groupId, userId) in [('g-old', 'old-soham'), ('g-new', 'new-soham')]) {
        await db.insert('groups', {'id': groupId, 'name': groupId,
            'createdAt': now, 'createdBy': userId});
        await db.insert('group_members',
            {'id': '$groupId-m', 'groupId': groupId, 'userId': userId});
      }

      final merged = await users.mergeDuplicateUsers(preferredUserId: 'new-soham');

      expect(merged, {'old-soham': 'new-soham'});
      expect(await repo.getAllGroupsForUser('new-soham'), hasLength(2));
      expect(await users.getUserById('old-soham'), isNull);
    });

    test('same-named people inside one event are not merged', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('users', {'id': 'rahul-1', 'name': 'Rahul', 'createdAt': now});
      await db.insert('users', {'id': 'rahul-2', 'name': 'Rahul', 'createdAt': now});
      for (final u in ['rahul-1', 'rahul-2']) {
        await db.insert('group_members',
            {'id': '$_groupId-$u', 'groupId': _groupId, 'userId': u});
      }

      expect(await users.mergeDuplicateUsers(), isEmpty);
    });
  });
}
