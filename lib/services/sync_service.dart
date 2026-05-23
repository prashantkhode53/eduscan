import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'api_service.dart';
import 'local_db_service.dart';
import 'storage_service.dart';

class SyncService {
  static final SyncService instance = SyncService._();
  SyncService._();

  bool _syncing = false;

  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;

    final results = await Connectivity().checkConnectivity();
    final isOnline = results.any((r) =>
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.ethernet);

    if (!isOnline) {
      _syncing = false;
      return;
    }

    int pushed = 0;
    int pulled = 0;
    String? errorMsg;

    try {
      // Push pending attendance records
      final pending = await LocalDbService.instance.getPendingQueue();
      if (pending.isNotEmpty) {
        final records = pending.map((r) => {
              'student_id': r['student_id'],
              'date': r['date'],
              'time_in': r['time_in'],
              'time_out': r['time_out'],
              'duration_mins': r['duration_mins'],
              'status': r['status'],
              'checkin_mode': r['checkin_mode'],
              'checkout_mode': r['checkout_mode'],
              'confidence_in': r['confidence_in'],
              'confidence_out': r['confidence_out'],
            }).toList();

        await ApiService.batchAttendance(records);
        final ids = pending.map((r) => r['local_id'] as int).toList();
        await LocalDbService.instance.markSynced(ids);
        pushed = ids.length;
      }

      // Pull active students
      final data = await ApiService.getStudents(status: 'active', limit: 1000);
      final students = (data['students'] as List).cast<Map<String, dynamic>>();
      await LocalDbService.instance.upsertStudents(students);
      pulled = students.length;

      await StorageService.saveLastSyncTime(DateTime.now());
    } catch (e) {
      errorMsg = e.toString();
    }

    await LocalDbService.instance.writeSyncLog(
      pushed: pushed,
      pulled: pulled,
      error: errorMsg,
    );

    _syncing = false;
  }

  double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0;
    double magA = 0;
    double magB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      magA += a[i] * a[i];
      magB += b[i] * b[i];
    }
    final denom = sqrt(magA) * sqrt(magB);
    if (denom == 0) return 0.0;
    return dot / denom;
  }

  Map<String, dynamic>? findBestMatchOffline(
    List<double> incoming,
    List<Map<String, dynamic>> students,
    double threshold,
  ) {
    Map<String, dynamic>? best;
    double bestScore = 0;
    for (final s in students) {
      final embedding = (s['face_embedding'] as List).cast<double>();
      final score = cosineSimilarity(incoming, embedding);
      if (score >= threshold && score > bestScore) {
        bestScore = score;
        best = {...s, 'confidence': score};
      }
    }
    return best;
  }
}
