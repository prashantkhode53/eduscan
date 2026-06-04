import 'dart:io';
import 'package:flutter/material.dart';
import 'package:jwt_decoder/jwt_decoder.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  String _statusMessage = 'Starting EduScan...';
  bool _isWakingUp   = false;
  bool _noInternet   = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _opacity = Tween<double>(begin: 0.0, end: 1.0)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));
    _controller.forward();
    Future.delayed(Duration.zero, _initApp);
  }

  Future<void> _initApp() async {
    try {
      await Future.delayed(const Duration(milliseconds: 800));

      // ── Quick network reachability check ───────────────────────────────────
      bool online = false;
      try {
        final result = await InternetAddress.lookup('google.com')
            .timeout(const Duration(seconds: 5));
        online = result.isNotEmpty && result.first.rawAddress.isNotEmpty;
      } catch (_) {
        online = false;
      }

      if (!online) {
        if (!mounted) return;
        setState(() {
          _noInternet   = true;
          _isWakingUp   = false;
          _statusMessage = '';
        });
        return;
      }

      // ── Server wake-up loop ────────────────────────────────────────────────
      if (mounted) {
        setState(() {
          _statusMessage = 'Connecting to server...';
          _isWakingUp    = true;
          _noInternet    = false;
        });
      }

      bool serverReady = false;
      int attempts = 0;
      while (!serverReady && attempts < 6) {
        serverReady = await ApiService.checkHealth();
        if (!serverReady) {
          attempts++;
          if (attempts == 1 && mounted) {
            setState(() {
              _statusMessage = 'Waking up server\n(first launch may take ~30s)...';
            });
          }
          await Future.delayed(const Duration(seconds: 5));
        }
      }

      if (!mounted) return;
      setState(() => _isWakingUp = false);

      if (!serverReady) {
        Navigator.of(context).pushReplacementNamed('/login');
        return;
      }

      setState(() => _statusMessage = 'Loading...');

      final token = await StorageService.getToken();
      if (!mounted) return;

      if (token != null && !JwtDecoder.isExpired(token)) {
        final payload = JwtDecoder.decode(token);
        final type    = payload['type'] as String?;
        if (type == 'academy') {
          final role = payload['role'] as String? ?? 'admin';
          switch (role) {
            case 'teacher': Navigator.of(context).pushReplacementNamed('/academy/teacher'); break;
            case 'student': Navigator.of(context).pushReplacementNamed('/academy/student'); break;
            case 'parent':  Navigator.of(context).pushReplacementNamed('/academy/parent');  break;
            default:        Navigator.of(context).pushReplacementNamed('/academy/dashboard');
          }
        } else {
          Navigator.of(context).pushReplacementNamed('/dashboard');
        }
      } else {
        final parentToken = await StorageService.getParentToken();
        if (!mounted) return;
        if (parentToken != null && !JwtDecoder.isExpired(parentToken)) {
          Navigator.of(context).pushReplacementNamed('/parent/dashboard');
        } else {
          Navigator.of(context).pushReplacementNamed('/login');
        }
      }
    } catch (e) {
      debugPrint('Splash init error: $e');
      if (mounted) Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  void _retry() {
    setState(() {
      _noInternet    = false;
      _isWakingUp    = false;
      _statusMessage = 'Starting EduScan...';
    });
    _initApp();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.primary,
      body: AnimatedBuilder(
        animation: _opacity,
        builder: (_, __) => Opacity(
          opacity: _opacity.value,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // App icon
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.face_retouching_natural,
                      size: 56, color: Color(0xFF1A56DB)),
                ),
                const SizedBox(height: 24),
                Text(
                  'EduScan',
                  style: theme.textTheme.headlineLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Know who's present. Always.",
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.85),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 48),

                // ── No-internet state ──────────────────────────────────────
                if (_noInternet) ...[
                  const Icon(Icons.wifi_off_rounded,
                      size: 48, color: Colors.white70),
                  const SizedBox(height: 16),
                  const Text(
                    'No Internet Connection',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "You're offline. Please check your\nWi-Fi or mobile data and try again.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  ElevatedButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try Again'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF1A56DB),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 36, vertical: 14),
                      textStyle: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30)),
                    ),
                  ),
                ]
                // ── Normal loading state ───────────────────────────────────
                else ...[
                  if (_isWakingUp)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    _statusMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.7)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      bottomSheet: Container(
        color: theme.colorScheme.primary,
        padding: const EdgeInsets.only(bottom: 24),
        child: Center(
          child: Text(
            'v1.0.0',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}
