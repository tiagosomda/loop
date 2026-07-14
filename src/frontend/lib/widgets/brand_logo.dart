import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

const _logoAsset = 'assets/branding/dev_loop_logo.png';
const scheduleAccelerationWindow = Duration(minutes: 3);

bool isNearScheduledTime(
  DateTime now,
  Iterable<String> scheduleTimes, {
  Duration window = scheduleAccelerationWindow,
}) {
  for (final time in scheduleTimes) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(time.trim());
    if (match == null) continue;

    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) continue;

    for (final dayOffset in const [-1, 0, 1]) {
      final scheduled = DateTime(
        now.year,
        now.month,
        now.day + dayOffset,
        hour,
        minute,
      );
      if (now.difference(scheduled).abs() <= window) return true;
    }
  }
  return false;
}

class DevLoopLogo extends StatelessWidget {
  const DevLoopLogo({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      _logoAsset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      semanticLabel: 'dev loop logo',
    );
  }
}

class SpinningDevLoopLogo extends StatefulWidget {
  const SpinningDevLoopLogo({
    super.key,
    this.size = 28,
    this.scheduleTimes = const [],
    this.tappable = false,
  });

  final double size;
  final List<String> scheduleTimes;

  /// When true, tapping the logo layers a burst of fast spins on top of the
  /// slow continuous rotation. Repeated taps (within a short window) extend
  /// and speed up the burst, capped at a reasonable maximum.
  final bool tappable;

  @override
  State<SpinningDevLoopLogo> createState() => _SpinningDevLoopLogoState();
}

class _SpinningDevLoopLogoState extends State<SpinningDevLoopLogo>
    with TickerProviderStateMixin {
  static const _slowPeriod = Duration(seconds: 24);
  static const _activePeriod = Duration(milliseconds: 1800);

  // Tap-burst tuning: each tap adds more turns to the burst and, up to a
  // point, speeds up subsequent turns — capped so it can't run away.
  static const _maxTapStreak = 6;
  static const _turnsPerTap = 1.1;
  static const _baseTurnDuration = Duration(milliseconds: 420);
  static const _minTurnDuration = Duration(milliseconds: 150);
  static const _tapStreakWindow = Duration(milliseconds: 700);

  late final AnimationController _controller;
  late final AnimationController _burst;
  Timer? _scheduleTimer;
  Timer? _tapStreakTimer;
  Duration? _currentPeriod;
  bool _animationsDisabled = false;
  int _tapStreak = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _burst = AnimationController(
      vsync: this,
      lowerBound: 0,
      upperBound: double.infinity,
    );
    _scheduleTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _syncSpeed(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animationsDisabled =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _syncSpeed();
  }

  @override
  void didUpdateWidget(SpinningDevLoopLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSpeed();
  }

  void _syncSpeed() {
    if (_animationsDisabled) {
      _controller.stop();
      return;
    }

    final period = isNearScheduledTime(DateTime.now(), widget.scheduleTimes)
        ? _activePeriod
        : _slowPeriod;
    if (_controller.isAnimating && period == _currentPeriod) return;

    _currentPeriod = period;
    _controller.repeat(period: period);
  }

  void _handleTap() {
    if (!widget.tappable || _animationsDisabled) return;

    final wasIdle = !_burst.isAnimating;

    _tapStreak = (_tapStreak + 1).clamp(1, _maxTapStreak);
    _tapStreakTimer?.cancel();
    _tapStreakTimer = Timer(_tapStreakWindow, () => _tapStreak = 0);

    // 0 on the first tap of a streak, 1 once the streak is maxed out.
    final speedUp = (_tapStreak - 1) / (_maxTapStreak - 1);
    final turnDurationMs =
        _baseTurnDuration.inMilliseconds -
        (_baseTurnDuration.inMilliseconds - _minTurnDuration.inMilliseconds) *
            speedUp;

    final target = _burst.value + _turnsPerTap;
    final duration = Duration(
      milliseconds: (turnDurationMs * _turnsPerTap).round(),
    );

    // The first tap eases in from a standstill; taps that land while a burst
    // is already spinning just extend it (easing out toward the new target)
    // so the motion doesn't stutter back to a dead stop between taps.
    _burst.animateTo(
      target,
      duration: duration,
      curve: wasIdle ? Curves.easeInOutCubic : Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scheduleTimer?.cancel();
    _tapStreakTimer?.cancel();
    _controller.dispose();
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logo = AnimatedBuilder(
      animation: Listenable.merge([_controller, _burst]),
      builder: (context, child) {
        final turns = _controller.value + _burst.value;
        return Transform.rotate(angle: turns * 2 * math.pi, child: child);
      },
      child: DevLoopLogo(size: widget.size),
    );

    if (!widget.tappable) return logo;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      child: logo,
    );
  }
}

class BrandTitle extends StatelessWidget {
  const BrandTitle({
    super.key,
    this.scheduleTimes = const [],
    this.showLogo = true,
  });

  final List<String> scheduleTimes;

  /// Whether to show the spinning logo alongside the "DEV LOOP" text.
  final bool showLogo;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showLogo) ...[
          SpinningDevLoopLogo(scheduleTimes: scheduleTimes),
          const SizedBox(width: 10),
        ],
        const Text('DEV LOOP'),
      ],
    );
  }
}
