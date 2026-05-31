import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'app.dart';
import 'providers/auth_provider.dart';
import 'providers/student_provider.dart';
import 'providers/attendance_provider.dart';
import 'providers/connectivity_provider.dart';
import 'providers/parent_auth_provider.dart';
import 'services/fcm_service.dart';

/// Navigator key exposed so FcmService can push routes from notification taps.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    // Initialise Firebase — required before FcmService.initialize()
    await Firebase.initializeApp();

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ConnectivityProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => StudentProvider()),
          ChangeNotifierProvider(create: (_) => AttendanceProvider()),
          ChangeNotifierProvider(create: (_) => ParentAuthProvider()),
        ],
        child: EduScanApp(navigatorKey: navigatorKey),
      ),
    );

    // Set up FCM after the widget tree is mounted
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FcmService.initialize(navigatorKey);
    });
  }, (error, stack) {
    debugPrint('Fatal error: $error');
    debugPrint('Stack: $stack');
  });
}
