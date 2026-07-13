import 'dart:async';

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
  });

  final double size;
  final List<String> scheduleTimes;

  @override
  State<SpinningDevLoopLogo> createState() => _SpinningDevLoopLogoState();
}

class _SpinningDevLoopLogoState extends State<SpinningDevLoopLogo>
    with SingleTickerProviderStateMixin {
  static const _slowPeriod = Duration(seconds: 24);
  static const _activePeriod = Duration(milliseconds: 1800);

  late final AnimationController _controller;
  Timer? _scheduleTimer;
  Duration? _currentPeriod;
  bool _animationsDisabled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
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

  @override
  void dispose() {
    _scheduleTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: DevLoopLogo(size: widget.size),
    );
  }
}

class BrandTitle extends StatelessWidget {
  const BrandTitle({super.key, this.scheduleTimes = const []});

  final List<String> scheduleTimes;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SpinningDevLoopLogo(scheduleTimes: scheduleTimes),
        const SizedBox(width: 10),
        const Text('DEV LOOP'),
      ],
    );
  }
}
