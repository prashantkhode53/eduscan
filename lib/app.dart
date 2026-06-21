import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'config/app_mode.dart';
import 'constants/app_colors.dart';
import 'providers/auth_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/student_registration_screen.dart';
import 'screens/student_list_screen.dart';
import 'screens/student_detail_screen.dart';
import 'screens/checkin_checkout_screen.dart';
import 'screens/attendance_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/academy_admin_dashboard.dart';
import 'screens/academy/parent_login_screen.dart';
import 'screens/academy/parent_dashboard_screen.dart';

class EduScanApp extends StatelessWidget {
  final GlobalKey<NavigatorState>? navigatorKey;
  const EduScanApp({super.key, this.navigatorKey});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        return MaterialApp(
          title: 'EduScan${AppMode.titleSuffix}',
          debugShowCheckedModeBanner: false,
          themeMode: auth.themeMode,
          theme: AppColors.lightTheme,
          darkTheme: AppColors.darkTheme,
          navigatorKey: navigatorKey,
          initialRoute: '/',
          onGenerateRoute: (settings) {
            Widget page;
            switch (settings.name) {
              case '/':
                page = const SplashScreen();
              case '/login':
                page = const LoginScreen();
              case '/dashboard':
                page = const DashboardScreen();
              case '/students':
                page = const StudentListScreen();
              case '/students/register':
                page = const StudentRegistrationScreen();
              case '/students/detail':
                final id = settings.arguments as String;
                page = StudentDetailScreen(studentId: id);
              case '/checkin':
                page = const CheckinCheckoutScreen();
              case '/attendance':
                page = const AttendanceScreen();
              case '/reports':
                page = const ReportsScreen();
              case '/settings':
                page = const SettingsScreen();

              // ── Parent routes ───────────────────────────────────────────
              case '/parent/login':
                page = const ParentLoginScreen();
              case '/parent/dashboard':
                page = const ParentDashboardScreen();

              // ── Academy routes ──────────────────────────────────────────
              case '/academy/dashboard':
                page = const AcademyAdminDashboard();
              // Phases 5-7: stubs route to admin dashboard until built
              case '/academy/teacher':
              case '/academy/student':
              case '/academy/parent':
                page = const AcademyAdminDashboard();

              default:
                page = const SplashScreen();
            }
            return PageRouteBuilder(
              settings: settings,
              pageBuilder: (_, __, ___) => page,
              transitionsBuilder: (_, animation, __, child) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(1.0, 0.0),
                    end: Offset.zero,
                  ).animate(CurvedAnimation(parent: animation, curve: Curves.easeInOut)),
                  child: child,
                );
              },
              transitionDuration: const Duration(milliseconds: 250),
            );
          },
        );
      },
    );
  }
}
