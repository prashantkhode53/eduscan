import 'package:flutter/material.dart';

/// A horizontal "running bar" that smoothly, continuously scrolls a single
/// message right-to-left. Shows ONLY the message it's given (the dashboard
/// feeds it the latest broadcast); it never rotates between messages.
///
/// Self-contained (AnimationController + Transform.translate) — no marquee
/// package dependency. When [message] changes, the scroll restarts from the
/// right so the newest announcement is shown from the beginning.
class NotificationTicker extends StatefulWidget {
  final String message;
  final VoidCallback? onTap;

  const NotificationTicker({super.key, required this.message, this.onTap});

  @override
  State<NotificationTicker> createState() => _NotificationTickerState();
}

class _NotificationTickerState extends State<NotificationTicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final _textKey = GlobalKey();
  double _textWidth = 0;

  @override
  void initState() {
    super.initState();
    // Duration is set per-layout (based on text width) for a constant speed.
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 12))
      ..repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant NotificationTicker old) {
    super.didUpdateWidget(old);
    if (old.message != widget.message) {
      // Restart from the right edge for the new (latest) message.
      _ctrl
        ..reset()
        ..repeat();
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  void _measure() {
    final ctx = _textKey.currentContext;
    if (ctx == null || !mounted) return;
    final w = ctx.size?.width ?? 0;
    if (w != _textWidth) {
      setState(() => _textWidth = w);
      // ~50 logical px/sec for a smooth, readable pace (min 6s).
      final secs = (w / 50).clamp(6, 60).toInt();
      _ctrl.duration = Duration(seconds: secs);
      _ctrl
        ..reset()
        ..repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primary,
      child: InkWell(
        onTap: widget.onTap,
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                color: Colors.black.withValues(alpha: 0.15),
                height: 36,
                child: const Center(
                  child: Icon(Icons.campaign, color: Colors.white, size: 18),
                ),
              ),
              Expanded(
                child: ClipRect(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final viewW = constraints.maxWidth;
                      return AnimatedBuilder(
                        animation: _ctrl,
                        builder: (context, child) {
                          // Travel from just off the right edge to fully past the
                          // left edge, so the whole message scrolls through.
                          final travel = viewW + _textWidth;
                          final dx = viewW - (_ctrl.value * travel);
                          return Transform.translate(
                            offset: Offset(dx, 0),
                            child: child,
                          );
                        },
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            widget.message,
                            key: _textKey,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.visible,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
