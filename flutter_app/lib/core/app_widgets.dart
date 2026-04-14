import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'dart:math' as math;

/// Returns the specific color based on confidence state, aligned with the dark theme.
Color confidenceColor(String state) {
  switch (state.toLowerCase()) {
    case 'tracking':
      return const Color(0xFF00E5FF); // Electric Teal
    case 'at_terminal':
      return const Color(0xFFF59E0B); // Amber/Orange
    case 'stale':
      return const Color(0xFF94A3B8); // Slate 400
    default:
      return const Color(0xFF334155); // Slate 700
  }
}

/// Refined back control: pops when possible, otherwise [fallbackLocation] (default home).
/// Updated for dark glassmorphism.
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
          foregroundColor: Colors.white,
          backgroundColor: const Color(0xFF0D1B2A).withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
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

/// Provides the dark background color.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF0D1B2A), // Map tile matching edge color
      ),
      child: child,
    );
  }
}

/// Glassmorphism card for content sections
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.useGlass = true,
  });

  final Widget child;
  final EdgeInsets padding;
  final bool useGlass;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: useGlass
            ? const Color(0xFF162534).withValues(alpha: 0.75)
            : const Color(0xFF122030),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 40,
            offset: Offset(0, 16),
          ),
        ],
      ),
      padding: padding,
      child: child,
    );
  }
}

/// A compact pill showing the route number.
class RoutePill extends StatelessWidget {
  const RoutePill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF001F3F), // Navy deep base
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.3)),
      ),
      child: Text(
        label.isEmpty ? 'BUS' : label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w900,
          color: const Color(0xFF00E5FF),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Generic chip for labels and status.
class ToneChip extends StatelessWidget {
  const ToneChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Specialized chip mapping string states to [confidenceColor].
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

/// Static map marker for generic points (e.g. stops).
class StopMapMarker extends StatelessWidget {
  const StopMapMarker({super.key, required this.routeCount});

  final int routeCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFF162534),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        routeCount > 9 ? '9+' : '$routeCount',
        style: const TextStyle(
          fontWeight: FontWeight.w900,
          color: Colors.white,
          fontSize: 10,
        ),
      ),
    );
  }
}

/// Represents the user's GPS location on the map.
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
      duration: const Duration(milliseconds: 2500),
    )..repeat();
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
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 60 * _controller.value,
              height: 60 * _controller.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF3B82F6).withValues(alpha: 1 - _controller.value),
                  width: 2,
                ),
              ),
            ),
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: const Color(0xFF3B82F6),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x663B82F6),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Live marker for a bus on the map, pulsing if actively tracking.
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
    final isTracking = widget.state == 'tracking';
    
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final scale = 1.0 + (_controller.value * 0.25);
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            if (isTracking)
              Transform.scale(
                scale: scale,
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.25),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFF162534), // Dark core
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.4),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                widget.routeLabel.isEmpty ? 'B' : widget.routeLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 10,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Shimmer placeholder item for loading states.
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({super.key, required this.width, required this.height, this.borderRadius = 8});

  final double width;
  final double height;
  final double borderRadius;

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
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
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: const [0.0, 0.5, 1.0],
              colors: [
                const Color(0xFF1E293B).withValues(alpha: 0.4),
                const Color(0xFF1E293B).withValues(alpha: 0.8),
                const Color(0xFF1E293B).withValues(alpha: 0.4),
              ],
              transform: _SlidingGradientTransform(slidePercent: _controller.value),
            ),
          ),
        );
      },
    );
  }
}

class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform({required this.slidePercent});
  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (slidePercent * 2 - 1), 0.0, 0.0);
  }
}
