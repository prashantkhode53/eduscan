import 'package:flutter/material.dart';

/// Shown on Windows when the user reaches a route that depends on mobile-only
/// hardware/plugins (live camera face scan, on-device face registration,
/// parent face-verified login). These features are intentionally excluded from
/// the Windows desktop build; they remain available in the Android app.
///
/// This is a safety net for routes — the corresponding entry-point buttons are
/// already hidden on Windows, so users should not normally land here.
class WindowsUnsupportedScreen extends StatelessWidget {
  final String featureName;
  const WindowsUnsupportedScreen({super.key, required this.featureName});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Not available on Windows')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.desktop_access_disabled_outlined,
                  size: 64, color: theme.colorScheme.outline),
              const SizedBox(height: 20),
              Text(
                '$featureName is not available on Windows',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              Text(
                'This feature relies on the device camera and on-device face '
                'recognition, which are supported only in the EduScan Android '
                'app. Please use the Android app for this task.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Go back'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
