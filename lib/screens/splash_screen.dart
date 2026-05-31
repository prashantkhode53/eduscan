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
  bool _isWakingUp = false;

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
    Future.delayed(Duration.zero, () {
      try {
        _initApp();
      } catch (e) {
        debugPrint('Splash init error: $e');
        if (mounted) Navigator.pushReplacementNamed(context, '/login');
      }
    });
  }

  Future<void> _initApp() async {
    try {
      await Future.delayed(const Duration(milliseconds: 800));

      if (mounted) {
        setState(() {
          _statusMessage = 'Connecting to server...';
          _isWakingUp = true;
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
        // Decode type + role to route to the correct dashboard
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
        // Check parent token before falling back to login
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
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha:0.2),
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
                    color: Colors.white.withValues(alpha:0.85),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 48),
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
                      fontSize: 13, color: Colors.white.withValues(alpha:0.7)),
                ),
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
              color: Colors.white.withValues(alpha:0.5),
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}
