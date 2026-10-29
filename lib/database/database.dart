import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';

class AppDatabase {
  static final AppDatabase _instance = AppDatabase._internal();
  static Database? _database;

  AppDatabase._internal();

  factory AppDatabase() {
    return _instance;
  }

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    try {
      final databasesPath = await getDatabasesPath();
      final path = join(databasesPath, 'expense_splitter.db');

      debugPrint('Database path: $path');

      return await openDatabase(
        path,
        version: schemaVersion,
        onConfigure: configure,
        onCreate: createTables,
        onUpgrade: upgrade,
        onOpen: (db) {
          debugPrint('Database opened successfully');
        },
      );
    } catch (e) {
      debugPrint('Error initializing database: $e');
      rethrow;
    }
  }

  static const int schemaVersion = 5;

  /// SQLite ignores FOREIGN KEY clauses unless this is switched on for every
  /// connection.
  static Future<void> configure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> createTables(Database db, int version) async {
    // Create User table
    await db.execute('''
      CREATE TABLE users(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        createdAt INTEGER NOT NULL
      )
    ''');

    // Create Group table
    await db.execute('''
      CREATE TABLE groups(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        createdAt INTEGER NOT NULL,
        createdBy TEXT NOT NULL,
        FOREIGN KEY (createdBy) REFERENCES users(id)
      )
    ''');

    // Create GroupMember table
    await db.execute('''
      CREATE TABLE group_members(
        id TEXT PRIMARY KEY,
        groupId TEXT NOT NULL,
        userId TEXT NOT NULL,
        FOREIGN KEY (groupId) REFERENCES groups(id),
        FOREIGN KEY (userId) REFERENCES users(id),
        UNIQUE(groupId, userId)
      )
    ''');

    // Create Expense table (tracks individual expenses/payments)
    await db.execute('''
      CREATE TABLE expenses(
        id TEXT PRIMARY KEY,
        groupId TEXT NOT NULL,
        paidByUserId TEXT NOT NULL,
        amount REAL NOT NULL,
        description TEXT,
        category TEXT NOT NULL DEFAULT 'other',
        note TEXT,
        splitType TEXT NOT NULL DEFAULT 'equal',
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (groupId) REFERENCES groups(id),
        FOREIGN KEY (paidByUserId) REFERENCES users(id)
      )
    ''');

    // Create Settlement table (tracks payments made)
    await db.execute('''
      CREATE TABLE settlements(
        id TEXT PRIMARY KEY,
        groupId TEXT NOT NULL,
        fromUserId TEXT NOT NULL,
        toUserId TEXT NOT NULL,
        amount REAL NOT NULL,
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (groupId) REFERENCES groups(id),
        FOREIGN KEY (fromUserId) REFERENCES users(id),
        FOREIGN KEY (toUserId) REFERENCES users(id)
      )
    ''');

    // Create ExpenseParticipants table (who took part in each expense and
    // what they owe; shareAmount NULL = equal split, used by pre-v5 rows)
    await db.execute('''
      CREATE TABLE expense_participants(
        expenseId TEXT NOT NULL,
        userId TEXT NOT NULL,
        shareAmount REAL,
        FOREIGN KEY (expenseId) REFERENCES expenses(id),
        FOREIGN KEY (userId) REFERENCES users(id),
        PRIMARY KEY (expenseId, userId)
      )
    ''');

    await _createIndexes(db);
  }

  /// Every screen loads a group's expenses and settlements by groupId.
  static Future<void> _createIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_expenses_group ON expenses(groupId)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_settlements_group ON settlements(groupId)',
    );
  }

  static Future<void> upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      // Add expenses table for version 2
      await db.execute('''
        CREATE TABLE expenses(
          id TEXT PRIMARY KEY,
          groupId TEXT NOT NULL,
          paidByUserId TEXT NOT NULL,
          amount REAL NOT NULL,
          description TEXT,
          createdAt INTEGER NOT NULL,
          FOREIGN KEY (groupId) REFERENCES groups(id),
          FOREIGN KEY (paidByUserId) REFERENCES users(id)
        )
      ''');
      debugPrint('Database upgraded to version 2: expenses table added');
    }
    if (oldVersion < 3) {
      // Add expense_participants table for version 3
      await db.execute('''
        CREATE TABLE expense_participants(
          expenseId TEXT NOT NULL,
          userId TEXT NOT NULL,
          FOREIGN KEY (expenseId) REFERENCES expenses(id),
          FOREIGN KEY (userId) REFERENCES users(id),
          PRIMARY KEY (expenseId, userId)
        )
      ''');
      debugPrint(
        'Database upgraded to version 3: expense_participants table added',
      );
    }

    if (oldVersion < 4) {
      // Add richer expense metadata for stats and filtering.
      await db.execute(
        "ALTER TABLE expenses ADD COLUMN category TEXT NOT NULL DEFAULT 'other'",
      );
      await db.execute('ALTER TABLE expenses ADD COLUMN note TEXT');
      await db.execute(
        "ALTER TABLE expenses ADD COLUMN splitType TEXT NOT NULL DEFAULT 'equal'",
      );
      debugPrint(
        'Database upgraded to version 4: expense metadata columns added',
      );
    }

    if (oldVersion < 5) {
      // Per-person shares, so an unequal/percentage split is one expense.
      await db.execute(
        'ALTER TABLE expense_participants ADD COLUMN shareAmount REAL',
      );

      // "Initial payment" rows were saved with no participants, so nobody
      // ever owed anything for them. Split them among the event's members.
      await db.execute('''
        INSERT INTO expense_participants (expenseId, userId)
        SELECT e.id, gm.userId
        FROM expenses e
        INNER JOIN group_members gm ON gm.groupId = e.groupId
        WHERE NOT EXISTS (
          SELECT 1 FROM expense_participants ep WHERE ep.expenseId = e.id
        )
      ''');

      // Never written by the app; balances come from expenses + settlements.
      await db.execute('DROP TABLE IF EXISTS expense_splits');
      await _createIndexes(db);
      debugPrint(
        'Database upgraded to version 5: per-person shares, '
        'initial payments split, expense_splits dropped',
      );
    }
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
    }
    _database = null;
  }
}
