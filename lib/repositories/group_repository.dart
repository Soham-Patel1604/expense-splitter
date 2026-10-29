import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/database.dart';
import '../models/expense.dart';
import '../models/friend_input.dart';
import '../models/group.dart';
import '../models/group_member.dart';
import '../models/settlement.dart';
import '../utils/balance_calculator.dart';
import 'user_repository.dart';

class GroupRepository {
  final AppDatabase _database;

  GroupRepository({required AppDatabase database}) : _database = database;

  /// Get all groups that contain the current user
  Future<List<Group>> getAllGroupsForUser(String userId) async {
    final db = await _database.database;

    final result = await db.query(
      'groups',
      where: 'id IN (SELECT groupId FROM group_members WHERE userId = ?)',
      whereArgs: [userId],
      orderBy: 'createdAt DESC',
    );

    return result.map((map) => Group.fromMap(map)).toList();
  }

  /// Create a comprehensive group with members (atomic transaction).
  /// Anything paid up front is split equally among every member.
  Future<void> createGroupWithMembers({
    required String name,
    required String currentUserId,
    required List<FriendInput> friends,
    double creatorAmountPaid = 0.0,
  }) async {
    final db = await _database.database;
    final groupId = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;

    try {
      await db.transaction((txn) async {
        // 1. Insert the group
        await txn.insert('groups', {
          'id': groupId,
          'name': name,
          'description': null,
          'createdAt': now,
          'createdBy': currentUserId,
        });

        // 2. Add the creator as the first member
        await txn.insert('group_members', {
          'id': const Uuid().v4(),
          'groupId': groupId,
          'userId': currentUserId,
        });

        final memberIds = <String>[currentUserId];
        final payments = <String, double>{
          if (creatorAmountPaid > 0) currentUserId: creatorAmountPaid,
        };

        // 3. Add friends, reusing anyone who already exists on this device
        for (final friend in friends) {
          final friendUserId = (await findOrCreateUser(
            txn,
            name: friend.name,
            phone: friend.phone,
          )).id;

          if (memberIds.contains(friendUserId)) {
            throw Exception(
              '${normalizeName(friend.name)} is already in this event',
            );
          }
          memberIds.add(friendUserId);

          await txn.insert('group_members', {
            'id': const Uuid().v4(),
            'groupId': groupId,
            'userId': friendUserId,
          });

          if (friend.amountPaid > 0) {
            payments[friendUserId] = friend.amountPaid;
          }
        }

        // 4. Up-front payments become expenses shared by the whole event
        for (final payment in payments.entries) {
          await _insertExpense(
            txn,
            groupId: groupId,
            paidByUserId: payment.key,
            amount: payment.value,
            description: 'Initial payment',
            shares: splitEqually(payment.value, memberIds),
            createdAt: now,
          );
        }
      });
    } catch (e) {
      debugPrint('Error creating group: $e');
      rethrow;
    }
  }

  /// Delete a group and all associated records in cascading order (atomic transaction)
  Future<void> deleteGroup(String groupId) async {
    final db = await _database.database;

    try {
      await db.transaction((txn) async {
        // 1. Delete settlements associated with this group
        await txn.delete(
          'settlements',
          where: 'groupId = ?',
          whereArgs: [groupId],
        );

        // 2. Delete expense participants for all expenses in this group
        // Note: Must be deleted before expenses due to foreign key
        await txn.delete(
          'expense_participants',
          where: 'expenseId IN (SELECT id FROM expenses WHERE groupId = ?)',
          whereArgs: [groupId],
        );

        // 3. Delete expenses for this group
        await txn.delete(
          'expenses',
          where: 'groupId = ?',
          whereArgs: [groupId],
        );

        // 4. Delete group members
        await txn.delete(
          'group_members',
          where: 'groupId = ?',
          whereArgs: [groupId],
        );

        // 5. Delete the group record itself
        await txn.delete(
          'groups',
          where: 'id = ?',
          whereArgs: [groupId],
        );
      });
    } catch (e) {
      debugPrint('Error deleting group: $e');
      rethrow;
    }
  }

  /// Get a single group by ID
  Future<Group?> getGroupById(String groupId) async {
    final db = await _database.database;

    final result = await db.query(
      'groups',
      where: 'id = ?',
      whereArgs: [groupId],
    );

    if (result.isEmpty) {
      return null;
    }

    return Group.fromMap(result.first);
  }

  /// Every member's net position in a group
  /// (positive = owed money, negative = owes money).
  Future<Map<String, double>> getGroupBalances(String groupId) async {
    final db = await _database.database;

    final memberRows = await db.query(
      'group_members',
      columns: ['userId'],
      where: 'groupId = ?',
      whereArgs: [groupId],
    );

    return computeBalances(
      memberIds: memberRows.map((row) => row['userId'] as String),
      expenses: await getGroupExpenses(groupId),
      settlements: await getGroupSettlements(groupId),
    );
  }

  /// The user's net balance in a group (positive = others owe them).
  Future<double> getUserNetBalanceForGroup(
    String groupId,
    String userId,
  ) async {
    final balances = await getGroupBalances(groupId);
    return balances[userId] ?? 0.0;
  }

  /// Get groups with balance view (includes calculated balance)
  Future<List<GroupBalanceView>> getGroupsWithBalance(String userId) async {
    final groups = await getAllGroupsForUser(userId);

    final List<GroupBalanceView> result = [];
    for (final group in groups) {
      final balance = await getUserNetBalanceForGroup(group.id, userId);
      result.add(GroupBalanceView(group: group, netBalance: balance));
    }

    return result;
  }

  /// Member count of every group the user belongs to, in one query.
  Future<Map<String, int>> getMemberCountsForUser(String userId) async {
    final db = await _database.database;

    final result = await db.rawQuery(
      '''
      SELECT groupId, COUNT(*) AS members
      FROM group_members
      WHERE groupId IN (SELECT groupId FROM group_members WHERE userId = ?)
      GROUP BY groupId
    ''',
      [userId],
    );

    return {
      for (final row in result)
        row['groupId'] as String: (row['members'] as num).toInt(),
    };
  }

  /// Update the name of a group
  Future<void> updateGroupName(String groupId, String newName) async {
    final trimmedName = newName.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('Group name cannot be empty');
    }

    final db = await _database.database;
    await db.update(
      'groups',
      {'name': trimmedName},
      where: 'id = ?',
      whereArgs: [groupId],
    );
  }

  /// Add a new member to an existing group, reusing the person if they
  /// already exist on this device
  Future<void> addNewMemberToGroup(
    String groupId,
    String name,
    String? phone,
  ) async {
    final cleanName = normalizeName(name);
    if (cleanName.isEmpty) {
      throw ArgumentError('Member name cannot be empty');
    }

    final db = await _database.database;

    try {
      await db.transaction((txn) async {
        // 1. Find or create the person
        final memberUserId = (await findOrCreateUser(
          txn,
          name: cleanName,
          phone: phone,
        )).id;

        // 2. Check if they are already a member of this group
        final existingMembership = await txn.query(
          'group_members',
          where: 'groupId = ? AND userId = ?',
          whereArgs: [groupId, memberUserId],
        );

        if (existingMembership.isNotEmpty) {
          throw Exception('$cleanName is already a member of this event');
        }

        // 3. Insert into group_members
        await txn.insert('group_members', {
          'id': const Uuid().v4(),
          'groupId': groupId,
          'userId': memberUserId,
        });
      });
    } catch (e) {
      debugPrint('Error adding new member to group: $e');
      rethrow;
    }
  }

  /// Get group members with the total each has paid, in join order
  Future<List<GroupMember>> getGroupMembersWithPayments(String groupId) async {
    final db = await _database.database;

    final result = await db.rawQuery(
      '''
      SELECT u.id, u.name, COALESCE(SUM(e.amount), 0) AS paid
      FROM group_members gm
      INNER JOIN users u ON u.id = gm.userId
      LEFT JOIN expenses e
        ON e.groupId = gm.groupId AND e.paidByUserId = gm.userId
      WHERE gm.groupId = ?
      GROUP BY u.id, u.name
      ORDER BY MIN(gm.rowid)
    ''',
      [groupId],
    );

    return result
        .map(
          (row) => GroupMember(
            userId: row['id'] as String,
            userName: row['name'] as String,
            amountPaid: (row['paid'] as num).toDouble(),
          ),
        )
        .toList();
  }

  /// Get existing settlements for a group
  Future<List<Settlement>> getGroupSettlements(String groupId) async {
    final db = await _database.database;

    final result = await db.rawQuery(
      '''
      SELECT s.*,
             u1.name as fromName,
             u2.name as toName
      FROM settlements s
      INNER JOIN users u1 ON s.fromUserId = u1.id
      INNER JOIN users u2 ON s.toUserId = u2.id
      WHERE s.groupId = ?
      ORDER BY s.createdAt DESC
    ''',
      [groupId],
    );

    return result
        .map(
          (map) => Settlement.fromMap(
            map,
            map['fromName'] as String,
            map['toName'] as String,
          ),
        )
        .toList();
  }

  /// Calculate pending settlements for a group using greedy debt
  /// simplification over the same balances every other screen shows
  Future<List<Settlement>> calculatePendingSettlements(String groupId) async {
    final members = await getGroupMembersWithPayments(groupId);
    final userNames = {for (final m in members) m.userId: m.userName};
    final balances = await getGroupBalances(groupId);

    return simplifyDebts(balances)
        .map(
          (transfer) => Settlement.calculated(
            fromUserId: transfer.fromUserId,
            fromUserName: userNames[transfer.fromUserId] ?? 'Unknown',
            toUserId: transfer.toUserId,
            toUserName: userNames[transfer.toUserId] ?? 'Unknown',
            amount: transfer.amount,
            groupId: groupId,
          ),
        )
        .toList();
  }

  /// Record a payment for a suggested settlement. [amount] defaults to the
  /// full suggested amount; a smaller value records a partial payment.
  /// Returns the new settlement's ID (used for undo).
  Future<String> markSettlementAsPaid(
    Settlement settlement, {
    double? amount,
  }) async {
    final paid = roundMoney(amount ?? settlement.amount);
    if (paid <= 0) {
      throw ArgumentError('Payment amount must be greater than zero');
    }

    final db = await _database.database;
    final settlementId = const Uuid().v4();

    await db.insert('settlements', {
      'id': settlementId,
      'groupId': settlement.groupId,
      'fromUserId': settlement.fromUserId,
      'toUserId': settlement.toUserId,
      'amount': paid,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });

    return settlementId;
  }

  /// Undo a recorded payment
  Future<void> deleteSettlement(String settlementId) async {
    final db = await _database.database;
    await db.delete(
      'settlements',
      where: 'id = ?',
      whereArgs: [settlementId],
    );
  }

  /// Add a new expense (atomic transaction). Without [shares] the amount is
  /// split equally among [participantIds]; with [shares] each person owes
  /// exactly their entry (unequal / percentage splits).
  Future<void> addExpense({
    required String groupId,
    required String description,
    required double amount,
    required String paidByUserId,
    required List<String> participantIds,
    Map<String, double>? shares,
    String category = 'other',
    String? note,
    String splitType = 'equal',
  }) async {
    final resolvedShares = _resolveShares(amount, participantIds, shares);
    final db = await _database.database;

    try {
      await db.transaction((txn) async {
        await _insertExpense(
          txn,
          groupId: groupId,
          paidByUserId: paidByUserId,
          amount: amount,
          description: description,
          category: category,
          note: note,
          splitType: splitType,
          shares: resolvedShares,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
      });
    } catch (e) {
      debugPrint('Error adding expense: $e');
      rethrow;
    }
  }

  /// Update an existing expense and its shares (atomic transaction)
  Future<void> updateExpense({
    required String expenseId,
    required String description,
    required double amount,
    required String paidByUserId,
    required List<String> participantIds,
    Map<String, double>? shares,
    String category = 'other',
    String? note,
    String splitType = 'equal',
  }) async {
    final resolvedShares = _resolveShares(amount, participantIds, shares);
    final db = await _database.database;

    try {
      await db.transaction((txn) async {
        // 1. Update the expense row
        await txn.update(
          'expenses',
          {
            'paidByUserId': paidByUserId,
            'amount': roundMoney(amount),
            'description': description,
            'category': category,
            'note': note,
            'splitType': splitType,
          },
          where: 'id = ?',
          whereArgs: [expenseId],
        );

        // 2. Replace the participants and their shares
        await txn.delete(
          'expense_participants',
          where: 'expenseId = ?',
          whereArgs: [expenseId],
        );
        await _insertShares(txn, expenseId, resolvedShares);
      });
    } catch (e) {
      debugPrint('Error updating expense: $e');
      rethrow;
    }
  }

  /// Validates the amount and turns the caller's split into exact shares.
  Map<String, double> _resolveShares(
    double amount,
    List<String> participantIds,
    Map<String, double>? shares,
  ) {
    if (amount <= 0) {
      throw ArgumentError('Expense amount must be greater than zero');
    }

    final Map<String, double> resolved;
    if (shares == null) {
      final cleanedIds = participantIds
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      resolved = splitEqually(amount, cleanedIds);
    } else {
      final total = shares.values.fold<double>(0.0, (a, b) => a + b);
      if ((total - amount).abs() > 0.01) {
        throw ArgumentError('Shares must add up to the expense amount');
      }
      resolved = fitSharesToTotal(amount, shares);
    }

    if (resolved.isEmpty) {
      throw ArgumentError('At least one participant is required');
    }
    return resolved;
  }

  Future<void> _insertExpense(
    DatabaseExecutor executor, {
    required String groupId,
    required String paidByUserId,
    required double amount,
    required String description,
    required Map<String, double> shares,
    required int createdAt,
    String category = 'other',
    String? note,
    String splitType = 'equal',
  }) async {
    final expenseId = const Uuid().v4();

    await executor.insert('expenses', {
      'id': expenseId,
      'groupId': groupId,
      'paidByUserId': paidByUserId,
      'amount': roundMoney(amount),
      'description': description,
      'category': category,
      'note': note,
      'splitType': splitType,
      'createdAt': createdAt,
    });

    await _insertShares(executor, expenseId, shares);
  }

  Future<void> _insertShares(
    DatabaseExecutor executor,
    String expenseId,
    Map<String, double> shares,
  ) async {
    for (final share in shares.entries) {
      await executor.insert('expense_participants', {
        'expenseId': expenseId,
        'userId': share.key,
        'shareAmount': share.value,
      });
    }
  }

  /// Delete an expense and its participants (atomic transaction)
  Future<void> deleteExpense(String expenseId) async {
    final db = await _database.database;
    try {
      await db.transaction((txn) async {
        // 1. Delete participants first due to foreign key relation
        await txn.delete(
          'expense_participants',
          where: 'expenseId = ?',
          whereArgs: [expenseId],
        );

        // 2. Delete the expense
        await txn.delete(
          'expenses',
          where: 'id = ?',
          whereArgs: [expenseId],
        );
      });
    } catch (e) {
      debugPrint('Error deleting expense: $e');
      rethrow;
    }
  }

  /// Get all expenses for a group, newest first (two queries in total)
  Future<List<Expense>> getGroupExpenses(String groupId) async {
    final db = await _database.database;

    final expenseRows = await db.rawQuery(
      '''
      SELECT e.*, u.name AS payerName
      FROM expenses e
      LEFT JOIN users u ON u.id = e.paidByUserId
      WHERE e.groupId = ?
      ORDER BY e.createdAt DESC, e.rowid DESC
    ''',
      [groupId],
    );

    final participantRows = await db.rawQuery(
      '''
      SELECT ep.expenseId, ep.userId, ep.shareAmount, u.name
      FROM expense_participants ep
      INNER JOIN expenses e ON e.id = ep.expenseId
      INNER JOIN users u ON u.id = ep.userId
      WHERE e.groupId = ?
      ORDER BY ep.rowid
    ''',
      [groupId],
    );

    final participantsByExpense = <String, List<Map<String, Object?>>>{};
    for (final row in participantRows) {
      participantsByExpense
          .putIfAbsent(row['expenseId'] as String, () => [])
          .add(row);
    }

    return expenseRows.map((expenseMap) {
      final participants =
          participantsByExpense[expenseMap['id'] as String] ?? const [];
      final participantIds = [
        for (final p in participants) p['userId'] as String,
      ];
      final amount = (expenseMap['amount'] as num).toDouble();

      // Rows written before v5 have no stored shares: they were equal splits.
      final hasStoredShares =
          participants.isNotEmpty &&
          participants.every((p) => p['shareAmount'] != null);
      final shares = hasStoredShares
          ? {
              for (final p in participants)
                p['userId'] as String: (p['shareAmount'] as num).toDouble(),
            }
          : splitEqually(amount, participantIds);

      return Expense.fromMap(
        expenseMap,
        (expenseMap['payerName'] as String?) ?? 'Unknown',
        participantIds,
        [for (final p in participants) p['name'] as String],
        shares,
      );
    }).toList();
  }

  /// Aggregate total spend by category for a group.
  Future<Map<String, double>> getGroupCategoryTotals(String groupId) async {
    final db = await _database.database;

    final result = await db.rawQuery(
      '''
      SELECT COALESCE(category, 'other') AS category,
             COALESCE(SUM(amount), 0) AS total
      FROM expenses
      WHERE groupId = ?
      GROUP BY COALESCE(category, 'other')
      ORDER BY total DESC
    ''',
      [groupId],
    );

    final categoryTotals = <String, double>{};
    for (final row in result) {
      final category = (row['category'] as String?) ?? 'other';
      categoryTotals[category] = (row['total'] as num).toDouble();
    }

    return categoryTotals;
  }

  /// Build the stats view model used by the insights page. Member net
  /// positions include settlements, so they match the Settle tab.
  Future<GroupExpenseStats> getGroupExpenseStats(String groupId) async {
    final members = await getGroupMembersWithPayments(groupId);
    final expenses = await getGroupExpenses(groupId);
    final settlements = await getGroupSettlements(groupId);
    final categoryTotals = await getGroupCategoryTotals(groupId);

    final amountOwedByUser = <String, double>{
      for (final member in members) member.userId: 0.0,
    };
    for (final expense in expenses) {
      expense.shares.forEach((userId, share) {
        amountOwedByUser[userId] = (amountOwedByUser[userId] ?? 0) + share;
      });
    }

    final balances = computeBalances(
      memberIds: members.map((m) => m.userId),
      expenses: expenses,
      settlements: settlements,
    );

    final memberStats = members
        .map(
          (member) => MemberExpenseStats(
            userId: member.userId,
            userName: member.userName,
            amountPaid: member.amountPaid,
            amountOwed: roundMoney(amountOwedByUser[member.userId] ?? 0),
            netBalance: balances[member.userId] ?? 0,
          ),
        )
        .toList()
      ..sort((a, b) => b.netBalance.compareTo(a.netBalance));

    return GroupExpenseStats(
      expenseCount: expenses.length,
      totalAmount: roundMoney(
        expenses.fold<double>(0.0, (sum, expense) => sum + expense.amount),
      ),
      categoryTotals: categoryTotals,
      memberStats: memberStats,
    );
  }
}
