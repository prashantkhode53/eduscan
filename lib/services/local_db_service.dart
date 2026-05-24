import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../constants/db_constants.dart';

class LocalDbService {
  static final LocalDbService instance = LocalDbService._();
  LocalDbService._();

  Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<void> init() async {
    _db = await _open();
  }

  Future<Database> _open() async {
    try {
      final dbPath = await getDatabasesPath();
      final path = join(dbPath, DbConstants.dbName);
      return openDatabase(
        path,
        version: DbConstants.dbVersion,
        onCreate: _onCreate,
      );
    } catch (e) {
      debugPrint('LocalDbService open error: $e');
      rethrow;
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE ${DbConstants.tableStudentsCache} (
        ${DbConstants.colId} TEXT PRIMARY KEY,
        ${DbConstants.colFirstName} TEXT NOT NULL,
        ${DbConstants.colLastName} TEXT NOT NULL,
        ${DbConstants.colClassGrade} TEXT NOT NULL,
        ${DbConstants.colDivision} TEXT NOT NULL,
        ${DbConstants.colRollNo} INTEGER,
        ${DbConstants.colFaceEmbedding} TEXT NOT NULL,
        ${DbConstants.colStatus} TEXT DEFAULT 'active',
        ${DbConstants.colSyncedAt} INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE ${DbConstants.tableAttendanceQueue} (
        ${DbConstants.colLocalId} INTEGER PRIMARY KEY AUTOINCREMENT,
        ${DbConstants.colStudentId} TEXT NOT NULL,
        ${DbConstants.colDate} TEXT NOT NULL,
        ${DbConstants.colTimeIn} TEXT,
        ${DbConstants.colTimeOut} TEXT,
        ${DbConstants.colDurationMins} INTEGER,
        ${DbConstants.colAttStatus} TEXT DEFAULT 'present',
        ${DbConstants.colCheckinMode} TEXT DEFAULT 'face_auto',
        ${DbConstants.colCheckoutMode} TEXT DEFAULT 'not_recorded',
        ${DbConstants.colConfidenceIn} REAL,
        ${DbConstants.colConfidenceOut} REAL,
        ${DbConstants.colIsSynced} INTEGER DEFAULT 0,
        ${DbConstants.colCreatedAt} INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE ${DbConstants.tableSyncLog} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ${DbConstants.colSyncedAtLog} INTEGER,
        ${DbConstants.colRecordsPushed} INTEGER DEFAULT 0,
        ${DbConstants.colRecordsPulled} INTEGER DEFAULT 0,
        ${DbConstants.colError} TEXT
      )
    ''');
  }

  // Students cache
  Future<void> upsertStudents(List<Map<String, dynamic>> students) async {
    final database = await db;
    final batch = database.batch();
    for (final s in students) {
      batch.insert(
        DbConstants.tableStudentsCache,
        {
          DbConstants.colId: s['id'],
          DbConstants.colFirstName: s['first_name'],
          DbConstants.colLastName: s['last_name'],
          DbConstants.colClassGrade: s['class_grade'],
          DbConstants.colDivision: s['division'],
          DbConstants.colRollNo: s['roll_no'],
          DbConstants.colFaceEmbedding: jsonEncode(s['face_embedding']),
          DbConstants.colStatus: s['status'] ?? 'active',
          DbConstants.colSyncedAt: DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> getCachedStudents({String? classGrade, String? division}) async {
    final database = await db;
    final conditions = <String>["${DbConstants.colStatus} = 'active'"];
    final args = <dynamic>[];
    if (classGrade != null) {
      conditions.add('${DbConstants.colClassGrade} = ?');
      args.add(classGrade);
    }
    if (division != null) {
      conditions.add('${DbConstants.colDivision} = ?');
      args.add(division);
    }
    final rows = await database.query(
      DbConstants.tableStudentsCache,
      where: conditions.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
    );
    return rows.map((r) {
      final m = Map<String, dynamic>.from(r);
      m['face_embedding'] = jsonDecode(m[DbConstants.colFaceEmbedding] as String);
      return m;
    }).toList();
  }

  Future<int> getCachedStudentCount() async {
    final database = await db;
    final result = await database.rawQuery(
      'SELECT COUNT(*) as cnt FROM ${DbConstants.tableStudentsCache}',
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  // Attendance queue
  Future<int> enqueueAttendance({
    required String studentId,
    required String date,
    String? timeIn,
    String? timeOut,
    int? durationMins,
    String status = 'present',
    String checkinMode = 'face_auto',
    String checkoutMode = 'not_recorded',
    double? confidenceIn,
    double? confidenceOut,
  }) async {
    final database = await db;
    return database.insert(DbConstants.tableAttendanceQueue, {
      DbConstants.colStudentId: studentId,
      DbConstants.colDate: date,
      DbConstants.colTimeIn: timeIn,
      DbConstants.colTimeOut: timeOut,
      DbConstants.colDurationMins: durationMins,
      DbConstants.colAttStatus: status,
      DbConstants.colCheckinMode: checkinMode,
      DbConstants.colCheckoutMode: checkoutMode,
      DbConstants.colConfidenceIn: confidenceIn,
      DbConstants.colConfidenceOut: confidenceOut,
      DbConstants.colIsSynced: 0,
      DbConstants.colCreatedAt: DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, dynamic>>> getPendingQueue() async {
    final database = await db;
    return database.query(
      DbConstants.tableAttendanceQueue,
      where: '${DbConstants.colIsSynced} = 0',
    );
  }

  Future<int> getPendingQueueCount() async {
    final database = await db;
    final result = await database.rawQuery(
      'SELECT COUNT(*) as cnt FROM ${DbConstants.tableAttendanceQueue} WHERE ${DbConstants.colIsSynced} = 0',
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  Future<void> markSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    final database = await db;
    final placeholders = ids.map((_) => '?').join(',');
    await database.rawUpdate(
      'UPDATE ${DbConstants.tableAttendanceQueue} SET ${DbConstants.colIsSynced} = 1 WHERE ${DbConstants.colLocalId} IN ($placeholders)',
      ids,
    );
  }

  // Sync log
  Future<void> writeSyncLog({
    required int pushed,
    required int pulled,
    String? error,
  }) async {
    final database = await db;
    await database.insert(DbConstants.tableSyncLog, {
      DbConstants.colSyncedAtLog: DateTime.now().millisecondsSinceEpoch,
      DbConstants.colRecordsPushed: pushed,
      DbConstants.colRecordsPulled: pulled,
      DbConstants.colError: error,
    });
  }
}
