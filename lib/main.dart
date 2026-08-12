import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'app.dart';
import 'providers/auth_provider.dart';
import 'providers/student_provider.dart';
import 'providers/attendance_provider.dart';
import 'providers/connectivity_provider.dart';
import 'providers/parent_auth_provider.dart';
import 'providers/academic_year_provider.dart';
import 'services/fcm_service.dart';

/// Navigator key exposed so FcmService can push routes from notification taps.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // ── Windows desktop: the offline SQLite cache uses sqflite, which has no
    // native Windows plugin. The FFI factory provides it. This runs ONLY on
    // Windows; Android keeps the default native sqflite factory untouched.
    if (Platform.isWindows) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    // Portrait lock is a mobile concern; on desktop the window is freely
    // resizable, so skip it on Windows.
    if (!Platform.isWindows) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }

    // Firebase / FCM are not configured for Windows (no Firebase desktop
    // setup). Initialising them on Windows would crash at startup, so this
    // runs on mobile only. Android behaviour is unchanged.
    if (!Platform.isWindows) {
      // Initialise Firebase — required before FcmService.initialize()
      await Firebase.initializeApp();
    }

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ConnectivityProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => StudentProvider()),
          ChangeNotifierProvider(create: (_) => AttendanceProvider()),
          ChangeNotifierProvider(create: (_) => ParentAuthProvider()),
          ChangeNotifierProvider(create: (_) => AcademicYearProvider()),
        ],
        child: EduScanApp(navigatorKey: navigatorKey),
      ),
    );

    // Set up FCM after the widget tree is mounted (mobile only — see above).
    if (!Platform.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FcmService.initialize(navigatorKey);
      });
    }
  }, (error, stack) {
    debugPrint('Fatal error: $error');
    debugPrint('Stack: $stack');
  });
}
