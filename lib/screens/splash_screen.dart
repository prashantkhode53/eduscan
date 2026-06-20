import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
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

  StreamSubscription<ConnectivityResult>? _connSub;
  bool _initRunning  = false;
  bool _offlineDialogOpen = false;

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

    // Auto-retry when the OS reports the network is back while we're stuck
    // on the offline screen.
    _connSub = Connectivity().onConnectivityChanged.listen((result) {
      final online = result == ConnectivityResult.mobile  ||
                     result == ConnectivityResult.wifi     ||
                     result == ConnectivityResult.ethernet;
      if (online && _noInternet && !_initRunning) {
        _retry();
      }
    });

    Future.delayed(Duration.zero, _initApp);
  }

  /// Lightweight HTTP 204 reachability probes. We try several so that one
  /// being blocked/down (corporate/edu Wi-Fi, regional blocks, carrier
  /// filtering) doesn't produce a false "offline". A 2xx/3xx from any of them
  /// is proof of real internet access — interface state alone is not.
  static const List<String> _reachabilityProbes = [
    'https://clients3.google.com/generate_204',     // Google connectivity check
    'https://www.gstatic.com/generate_204',         // Google CDN, often unblocked
    'https://captive.apple.com/hotspot-detect.html', // Apple captive-portal probe
    'https://cloudflare.com/cdn-cgi/trace',          // independent of Google
  ];

  /// Returns true once real internet access is confirmed. Retries with
  /// backoff so a cold-start race (network stack still coming up) doesn't
  /// flip us to the offline screen on a single transient miss.
  Future<bool> _isReallyOnline() async {
    // 1) Cheap interface gate — if there's truly no interface, skip the probes.
    try {
      final conn = await Connectivity().checkConnectivity();
      final hasInterface = conn == ConnectivityResult.mobile ||
                           conn == ConnectivityResult.wifi    ||
                           conn == ConnectivityResult.ethernet;
      debugPrint('[net] interface=$conn hasInterface=$hasInterface');
      if (!hasInterface) return false;
    } catch (e) {
      debugPrint('[net] connectivity check failed: $e (continuing to probes)');
    }

    // 2) HTTP reachability with retries + backoff (1.5s, 3s, 4.5s ...).
    const maxAttempts = 4;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (await _probeAny()) {
        debugPrint('[net] online confirmed on attempt $attempt');
        return true;
      }
      // Our own backend counts too: if it answers, the user is online for our
      // purposes even if the public probes are blocked on this network.
      if (await ApiService.checkHealth()) {
        debugPrint('[net] online confirmed via backend health on attempt $attempt');
        return true;
      }
      debugPrint('[net] attempt $attempt/$maxAttempts failed');
      if (attempt < maxAttempts) {
        await Future.delayed(Duration(milliseconds: 1500 * attempt));
      }
    }
    debugPrint('[net] all $maxAttempts attempts failed — treating as offline');
    return false;
  }

  /// Hits the reachability probes; true if any returns a non-error status.
  Future<bool> _probeAny() async {
    for (final url in _reachabilityProbes) {
      try {
        final res = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 6));
        // 2xx/3xx = real connectivity. A captive portal typically rewrites
        // these to a 200 with HTML, so for the strict 204 probes we also
        // require an empty body to avoid being fooled by a portal page.
        final ok = res.statusCode >= 200 && res.statusCode < 400;
        final isStrict204 = url.endsWith('generate_204');
        final passed = ok && (!isStrict204 || res.body.isEmpty);
        debugPrint('[net] probe $url -> ${res.statusCode} '
            '(len=${res.body.length}) passed=$passed');
        if (passed) return true;
      } on TimeoutException {
        debugPrint('[net] probe $url -> TIMEOUT');
      } on SocketException catch (e) {
        debugPrint('[net] probe $url -> SocketException: ${e.message}');
      } catch (e) {
        debugPrint('[net] probe $url -> error: $e');
      }
    }
    return false;
  }

  Future<void> _initApp() async {
    if (_initRunning) return;
    _initRunning = true;
    try {
      await Future.delayed(const Duration(milliseconds: 800));

      // ── Real internet reachability check ───────────────────────────────────
      // Validates actual internet access (not just an interface being up) by
      // hitting a lightweight HTTP 204 endpoint, with retries + backoff so a
      // cold-start race (network stack not ready yet) doesn't produce a false
      // "offline". Only after every attempt fails do we treat it as offline.
      final online = await _isReallyOnline();

      if (!online) {
        if (!mounted) return;
        setState(() {
          _noInternet   = true;
          _isWakingUp   = false;
          _statusMessage = '';
        });
        _showOfflineDialog();
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
    } finally {
      _initRunning = false;
    }
  }

  void _retry() {
    if (_initRunning) return;
    // Dismiss the offline prompt if it's open before re-running init.
    if (_offlineDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      _offlineDialogOpen = false;
    }
    setState(() {
      _noInternet    = false;
      _isWakingUp    = false;
      _statusMessage = 'Starting EduScan...';
    });
    _initApp();
  }

  /// Blocking prompt shown when the app opens with no network.
  /// Auto-dismisses via [_retry] when connectivity returns.
  Future<void> _showOfflineDialog() async {
    if (_offlineDialogOpen || !mounted) return;
    _offlineDialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.wifi_off_rounded, size: 40),
        title: const Text('No internet connection'),
        content: const Text(
          "EduScan needs an internet connection to start.\n\n"
          "Please check your Wi-Fi or mobile data — we'll reconnect "
          "automatically once you're back online.",
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
            onPressed: () => SystemNavigator.pop(),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Try Again'),
          ),
        ],
      ),
    );
    _offlineDialogOpen = false;
  }

  @override
  void dispose() {
    _connSub?.cancel();
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
                    'Please connect to the network.',
                    textAlign: TextAlign.center,
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
