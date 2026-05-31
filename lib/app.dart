import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

class EduScanApp extends StatelessWidget {
  const EduScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        return MaterialApp(
          title: 'EduScan',
          debugShowCheckedModeBanner: false,
          themeMode: auth.themeMode,
          theme: AppColors.lightTheme,
          darkTheme: AppColors.darkTheme,
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
