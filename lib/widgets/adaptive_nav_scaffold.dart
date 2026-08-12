import 'package:flutter/material.dart';
import '../utils/responsive.dart';

/// A single navigation destination shared by the desktop rail and the mobile
/// bottom bar.
class AdaptiveNavDestination {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const AdaptiveNavDestination({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

/// A scaffold that adapts its primary navigation to the window size.
///
/// * On the Windows desktop build, when the window is at least
///   [Responsive.desktopBreakpoint] wide, navigation is shown as a persistent
///   left [NavigationRail] (standard desktop pattern), with an optional
///   [railHeader] (e.g. app/academy identity) and [railFooter] (e.g. user
///   avatar / actions).
/// * Otherwise it falls back to the original bottom [NavigationBar], so phones
///   and narrow windows keep the existing mobile experience untouched.
///
/// This widget is **presentation only**. It owns no state: the selected index
/// and the body are supplied and controlled by the caller exactly as before, so
/// behaviour, navigation indices and the underlying `IndexedStack` are
/// unchanged. Callers that want the mobile look on Android simply never hit the
/// desktop branch (it is gated on [Responsive.isDesktop]).
class AdaptiveNavScaffold extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AdaptiveNavDestination> destinations;
  final Widget body;

  /// Shown above the rail destinations on desktop (e.g. logo + app name).
  final Widget? railHeader;

  /// Shown below the rail destinations on desktop (e.g. user avatar / logout).
  final Widget? railFooter;

  /// Optional floating action button (kept for both layouts).
  final Widget? floatingActionButton;

  const AdaptiveNavScaffold({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.body,
    this.railHeader,
    this.railFooter,
    this.floatingActionButton,
  });

  @override
  Widget build(BuildContext context) {
    final useRail = Responsive.isDesktop(context);

    if (!useRail) {
      // ── Original mobile layout (Android + narrow windows) ────────────────
      return Scaffold(
        body: body,
        floatingActionButton: floatingActionButton,
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: onDestinationSelected,
          destinations: destinations
              .map((d) => NavigationDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.activeIcon),
                    label: d.label,
                  ))
              .toList(),
        ),
      );
    }

    // ── Desktop layout: persistent left navigation rail ──────────────────────
    final theme = Theme.of(context);
    final extended = Responsive.widthOf(context) >= 1180;

    return Scaffold(
      floatingActionButton: floatingActionButton,
      body: Row(
        children: [
          _DesktopRail(
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            destinations: destinations,
            extended: extended,
            header: railHeader,
            footer: railFooter,
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: theme.dividerTheme.color ??
                theme.colorScheme.outlineVariant,
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _DesktopRail extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AdaptiveNavDestination> destinations;
  final bool extended;
  final Widget? header;
  final Widget? footer;

  const _DesktopRail({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.extended,
    this.header,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: extended ? 232 : 80,
      color: theme.navigationRailTheme.backgroundColor ??
          theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(extended ? 20 : 12, 20, 12, 12),
              child: header,
            ),
            Divider(height: 1, color: theme.dividerTheme.color),
          ],
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  for (var i = 0; i < destinations.length; i++)
                    _RailTile(
                      destination: destinations[i],
                      selected: i == selectedIndex,
                      extended: extended,
                      onTap: () => onDestinationSelected(i),
                    ),
                ],
              ),
            ),
          ),
          if (footer != null) ...[
            Divider(height: 1, color: theme.dividerTheme.color),
            Padding(
              padding: EdgeInsets.all(extended ? 12 : 8),
              child: footer,
            ),
          ],
        ],
      ),
    );
  }
}

class _RailTile extends StatelessWidget {
  final AdaptiveNavDestination destination;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  const _RailTile({
    required this.destination,
    required this.selected,
    required this.extended,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected
        ? scheme.primary
        : scheme.onSurface.withValues(alpha: 0.72);

    final tile = Container(
      margin: EdgeInsets.symmetric(horizontal: extended ? 12 : 10, vertical: 3),
      decoration: BoxDecoration(
        color: selected ? scheme.primary.withValues(alpha: 0.12) : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: extended ? 14 : 0, vertical: 12),
            child: extended
                ? Row(
                    children: [
                      Icon(selected ? destination.activeIcon : destination.icon,
                          color: fg, size: 22),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          destination.label,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: fg,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Icon(selected ? destination.activeIcon : destination.icon,
                          color: fg, size: 24),
                      const SizedBox(height: 4),
                      Text(
                        destination.label,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: fg,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );

    if (extended) return tile;
    // Collapsed rail shows a tooltip with the full label on hover.
    return Tooltip(message: destination.label, child: tile);
  }
}
