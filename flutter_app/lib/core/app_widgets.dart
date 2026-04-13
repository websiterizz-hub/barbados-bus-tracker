import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Refined back control: pops when possible, otherwise [fallbackLocation] (default home).
class AppBarBackAction extends StatelessWidget {
  const AppBarBackAction({super.key, this.fallbackLocation = '/'});

  final String fallbackLocation;

  @override
  Widget build(BuildContext context) {
    final canPop = GoRouter.of(context).canPop();
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: IconButton(
        tooltip: 'Back',
        style: IconButton.styleFrom(
          foregroundColor: const Color(0xFF132221),
          backgroundColor: Colors.white.withValues(alpha: 0.72),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0x140B7A75)),
          ),
          padding: const EdgeInsets.all(10),
          minimumSize: const Size(44, 44),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 17),
        onPressed: () {
          if (canPop) {
            context.pop();
          } else {
            context.go(fallbackLocation);
          }
        },
      ),
    );
  }
}

Color confidenceColor(String state) {
  switch (state) {
    case 'tracking':
      return const Color(0xFF0B7A75);
    case 'at_terminal':
      return const Color(0xFFE09F27);
    case 'stale':
      return const Color(0xFF9B4D3D);
    default:
      return const Color(0xFF355C7D);
  }
}

class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFF8F1DB),
            Color(0xFFE0F3F2),
            Color(0xFFF5E4C6),
            Color(0xFFDDEDF0),
          ],
        ),
      ),
      child: child,
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0x140B7A75)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 30,
            offset: Offset(0, 12),
          ),
        ],
      ),
      padding: padding,
      child: child,
    );
  }
}

class RoutePill extends StatelessWidget {
  const RoutePill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F7F4),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label.isEmpty ? 'Route' : label,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class ToneChip extends StatelessWidget {
  const ToneChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class ConfidenceChip extends StatelessWidget {
  const ConfidenceChip({super.key, required this.state, this.label});

  final String state;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return ToneChip(
      label: label ?? state.replaceAll('_', ' '),
      color: confidenceColor(state),
    );
  }
}

class StopMapMarker extends StatelessWidget {
  const StopMapMarker({super.key, required this.routeCount});

  final int routeCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFE09F27), width: 3),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        routeCount > 9 ? '9+' : '$routeCount',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: const Color(0xFF132221),
        ),
      ),
    );
  }
}

class UserLocationMarker extends StatefulWidget {
  const UserLocationMarker({super.key});

  @override
  State<UserLocationMarker> createState() => _UserLocationMarkerState();
}

class _UserLocationMarkerState extends State<UserLocationMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final pulse = 1 + (_controller.value * 0.35);
        return Stack(
          alignment: Alignment.center,
          children: [
            Transform.scale(
              scale: pulse,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: const Color(0xFF355C7D).withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: const Color(0xFF355C7D),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
              ),
            ),
          ],
        );
      },
    );
  }
}

class BusPulseMarker extends StatefulWidget {
  const BusPulseMarker({
    super.key,
    required this.state,
    required this.routeLabel,
  });

  final String state;
  final String routeLabel;

  @override
  State<BusPulseMarker> createState() => _BusPulseMarkerState();
}

class _BusPulseMarkerState extends State<BusPulseMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = confidenceColor(widget.state);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final scale = widget.state == 'tracking'
            ? 0.95 + (_controller.value * 0.35)
            : 1.0 + (_controller.value * 0.18);
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Transform.scale(
              scale: scale,
              child: Container(
                width: widget.state == 'tracking' ? 36 : 30,
                height: widget.state == 'tracking' ? 36 : 30,
                decoration: BoxDecoration(
                  color: color.withValues(
                    alpha: widget.state == 'tracking' ? 0.18 : 0.12,
                  ),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 12,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.directions_bus_rounded,
                size: 15,
                color: Colors.white,
              ),
            ),
            Positioned(
              bottom: -20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  widget.routeLabel.isEmpty ? 'Bus' : widget.routeLabel,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF132221),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
