import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:ebike/globals.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';



enum IndicatorDirection { none, left, right }
enum LightBeam { low, high }

class TurnIndicatorBar extends StatefulWidget {
  final IndicatorDirection direction;
  final LightBeam beam;
  final double height;
  final Duration speed;

  const TurnIndicatorBar({
    Key? key,
    required this.direction,
    this.beam = LightBeam.low,
    this.height = 120,
    this.speed = const Duration(milliseconds: 1400),
  }) : super(key: key);

  @override
  State<TurnIndicatorBar> createState() => _TurnIndicatorBarState();
}

class _TurnIndicatorBarState extends State<TurnIndicatorBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    
    _controller = AnimationController(
      vsync: this,
      duration: widget.speed,
    )..addListener(() {
        if (mounted) setState(() {});
      });
    _maybeAnimate();
  }

  @override
  void didUpdateWidget(covariant TurnIndicatorBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.direction != widget.direction ||
        oldWidget.speed != widget.speed) {
      _controller.duration = widget.speed;
      _maybeAnimate();
    }
  }

  void _maybeAnimate() {
    if (widget.direction == IndicatorDirection.none) {
      _controller.stop();
      _controller.reset();
    } else {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool active = widget.direction != IndicatorDirection.none;
    return IgnorePointer(
      ignoring: true,
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: LayoutBuilder(
            builder: (context, constraints) {
              final double width = constraints.maxWidth;
              // progress 0..1 left-to-right; invert for right-to-left if needed
              double t = _controller.value;
              if (widget.direction == IndicatorDirection.left) {
                t = 1 - t;
              }
              final double x = ui.lerpDouble(0, width, t) ?? 0;

              return Stack(
                children: [
                  // Subsurface rolling blue glow from below the bottom edge
                  if (active)
                    Positioned(
                      left: x - 140,
                      bottom: -36, // center below the bottom edge
                      width: 280,
                      height: widget.height + 72,
                      child: const _SubsurfaceGlow(),
                    ),

                  // Bottom-right arrows showing direction
                  Positioned(
                    right: 12,
                    bottom: 8,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Beam icon just above arrows
                        Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: Icon(
                            Icons.light_mode,
                            size: 18,
                            color: widget.beam == LightBeam.high
                                ? Colors.lightBlueAccent
                                : Colors.white38,
                          ),
                        ),
                        _ArrowIcon(
                          isActive: widget.direction == IndicatorDirection.left,
                          icon: Icons.keyboard_double_arrow_left,
                        ),
                        const SizedBox(width: 6),
                        _ArrowIcon(
                          isActive: widget.direction == IndicatorDirection.right,
                          icon: Icons.keyboard_double_arrow_right,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
  }
}

class _ArrowIcon extends StatelessWidget {
  final bool isActive;
  final IconData icon;
  const _ArrowIcon({required this.isActive, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Icon(
      icon,
      size: 22,
      color: isActive ? Colors.lightBlueAccent : Colors.white24,
    );
  }
}

class _SubsurfaceGlow extends StatelessWidget {
  const _SubsurfaceGlow();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SubsurfaceGlowPainter(),
    );
  }
}

class _SubsurfaceGlowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Draw a soft elliptical glow whose center sits below the bottom edge.
    final double radius = size.width * 0.45;
    final double centerBelow = size.height * 0.55; // how far below bottom

    final Paint paint = Paint()
      ..shader = ui.Gradient.radial(
        Offset(size.width / 2, size.height + centerBelow),
        radius,
        const [
          Color(0xFF2196F3),
          Color(0x802196F3),
          Color(0x1A2196F3),
          Colors.transparent,
        ],
        const [0.0, 0.18, 0.55, 1.0],
      )
      ..blendMode = BlendMode.plus;

    // Scale vertically to make it more like a horizon glow.
    canvas.save();
    canvas.scale(1.0, 0.45);
    canvas.drawCircle(
      Offset(size.width / 2, (size.height + centerBelow) / 0.45),
      radius,
      paint,
    );
    canvas.restore();

    // Optional faint top fade to mimic foggy horizon
    final Rect topFade = Rect.fromLTWH(0, 0, size.width, size.height);
    final Paint fadePaint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        Offset(0, size.height),
        [Colors.black.withOpacity(0.0), Colors.black.withOpacity(0.35)],
        const [0.0, 1.0],
      );
    canvas.drawRect(topFade, fadePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _IndicatorLinePainter extends CustomPainter {
  final bool active;
  _IndicatorLinePainter({required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint base = Paint()
      ..color = Colors.white.withOpacity(0.10)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final Offset p1 = Offset(12, size.height / 2);
    final Offset p2 = Offset(size.width - 12, size.height / 2);
    canvas.drawLine(p1, p2, base);

    if (active) {
      final Paint glow = Paint()
        ..color = const Color(0x332196F3)
        ..strokeWidth = 12
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawLine(p1, p2, glow);
    }
  }

  @override
  bool shouldRepaint(covariant _IndicatorLinePainter oldDelegate) {
    return oldDelegate.active != active;
  }
}

class BeamIndicator extends StatelessWidget {
  final LightBeam beam;
  const BeamIndicator({Key? key, required this.beam}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bool isHigh = beam == LightBeam.high;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isHigh ? const Color(0x332196F3) : Colors.white12,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isHigh ? Colors.lightBlueAccent.withOpacity(0.7) : Colors.white24,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.light_mode,
            size: 18,
            color: isHigh ? Colors.lightBlueAccent : Colors.white70,
          ),
          const SizedBox(width: 6),
          Text(
            isHigh ? 'HIGH' : 'LOW',
            style: GoogleFonts.spaceGrotesk(
              color: isHigh ? Colors.lightBlueAccent : Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class ModeTabs extends StatelessWidget {
  final String selectedTab;
  final ValueChanged<String> onTabChanged;
  final double menuWidth;
  final List<String> tabs;

  const ModeTabs({
    Key? key,
    required this.selectedTab,
    required this.onTabChanged,
    this.menuWidth = 140,
    this.tabs = const ['CRUISE', 'SPORT', 'ECO'],
  }) : super(key: key);

  // Local glassmorphic container used by each tab
  Widget _glassmorphicContainer({
    required Widget child,
    required bool isSelected,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
      decoration: BoxDecoration(
        gradient: isSelected
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF0A2540).withOpacity(0.4),
                  const Color(0xFF0A2540).withOpacity(0.0),
                ],
              )
            : null,
        color: isSelected ? null : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: const Color(0xFF0A2540).withOpacity(0.1),
                  blurRadius: 10,
                  spreadRadius: 0,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: child,
    );
  }

  Widget _buildTabItem(BuildContext context, String tabName) {
    final isSelected = selectedTab == tabName;
    return GestureDetector(
      onTap: () => onTabChanged(tabName),
      child: _glassmorphicContainer(
        isSelected: isSelected,
        child: Text(
          tabName,
          style: GoogleFonts.spaceGrotesk(
            color: isSelected ? Colors.white : Pallet.font1.withOpacity(0.7),
            fontSize: 18,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: menuWidth,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 18),
            _buildTabItem(context, tabs[0]),
            const SizedBox(height: 5),
            _buildTabItem(context, tabs[1]),
            const SizedBox(height: 5),
            _buildTabItem(context, tabs[2]),
          ],
        ),
      ),
    );
  }
}

class Controls extends StatefulWidget {
  final double initialDistanceKm;
  final bool initialLightOn;
  final bool initialReverse;
  final ValueChanged<double>? onDistanceChanged;
  final ValueChanged<bool>? onLightChanged;
  final ValueChanged<bool>? onReverseChanged;

  // Use initializing formals (this.xxx). Don't re-initialize them in the initializer list.
  const Controls({
    Key? key,
    this.initialDistanceKm = 0.0,
    this.initialLightOn = false,
    this.initialReverse = false,
    this.onDistanceChanged,
    this.onLightChanged,
    this.onReverseChanged,
  }) : super(key: key);

  @override
  State<Controls> createState() => _ControlsState();
}

class _ControlsState extends State<Controls> {
  late double _distanceKm;
  late bool _isLightOn;
  late bool _isReverse;

  @override
  void initState() {
    super.initState();
    _distanceKm = widget.initialDistanceKm;
    _isLightOn = widget.initialLightOn;
    _isReverse = widget.initialReverse;
  }

  Widget _power({
    required String title,
    required String value,
    required String unit,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 88,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0.05),
              Colors.white.withOpacity(0.1),
            ],
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 10,
                color: Colors.white.withOpacity(0.8),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 5),
            SizedBox(
              height: 23,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    value,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 3.5),
                  Text(
                    unit,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Colors.indigo,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton({
    required bool active,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? activeColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          vertical: 8,
          horizontal: 12,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0.1),
              Colors.white.withOpacity(0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? (activeColor ?? Colors.yellow).withOpacity(0.6)
                : Colors.white.withOpacity(0.2),
            width: 1,
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: (activeColor ?? Colors.yellow).withOpacity(0.18),
                    blurRadius: 8,
                    spreadRadius: 0,
                    offset: const Offset(0, 0),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: active ? (activeColor ?? Colors.yellow) : Colors.white.withOpacity(0.7),
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.spaceGrotesk(
                color: active ? (activeColor ?? Colors.yellow) : Colors.white.withOpacity(0.85),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(15),
      child: Container(
        width: 220,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF0A2540).withOpacity(0.1),
              const Color(0xFF0A2540).withOpacity(0.3),
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _power(title: "Voltage", value: "52", unit: "V"),
                const SizedBox(width: 10),
                _power(title: "Current", value: "22", unit: "A"),
              ],
            ),
            const SizedBox(height: 10),
            // Row(
            //   children: [
            //     Text(
            //       _distanceKm.toStringAsFixed(1),
            //       style: GoogleFonts.spaceGrotesk(
            //         color: Colors.white,
            //         fontSize: 16,
            //         fontWeight: FontWeight.w700,
            //       ),
            //     ),
            //     const SizedBox(width: 2.5),
            //     Text(
            //       'km',
            //       style: GoogleFonts.spaceGrotesk(
            //         color: Colors.white.withOpacity(0.85),
            //         fontSize: 14,
            //         fontWeight: FontWeight.w500,
            //       ),
            //     ),
            //   ],
            // ),
            // const SizedBox(height: 12),
            // Light button inside the power box
            _actionButton(
              active: _isLightOn,
              icon: _isLightOn ? Icons.lightbulb : Icons.lightbulb_outline,
              label: _isLightOn ? 'LIGHT ON' : 'LIGHT OFF',
              onTap: () {
                setState(() {
                  _isLightOn = !_isLightOn;
                });
                widget.onLightChanged?.call(_isLightOn);
              },
              activeColor: Colors.yellow,
            ),
            const SizedBox(height: 8),
            // Reverse mode button
            _actionButton(
              active: _isReverse,
              icon: _isReverse ? Icons.rotate_left : Icons.swap_horiz,
              label: _isReverse ? 'REVERSE' : 'FORWARD',
              onTap: () {
                setState(() {
                  _isReverse = !_isReverse;
                });
                widget.onReverseChanged?.call(_isReverse);
              },
              activeColor: Colors.redAccent,
            ),
          ],
        ),
      ),
    );
  }
}


class BatteryWidget extends StatefulWidget {
  /// optional initial percent (default 87)
  final int initialPercent;

  /// periodic update interval
  final Duration updateInterval;

  /// optional callback when percent changes
  final ValueChanged<int>? onChanged;

  const BatteryWidget({
    Key? key,
    this.initialPercent = 87,
    this.updateInterval = const Duration(seconds: 5),
    this.onChanged,
  }) : super(key: key);

  @override
  State<BatteryWidget> createState() => _BatteryWidgetState();
}

class _BatteryWidgetState extends State<BatteryWidget> {
  late int _percent;
  Timer? _timer;
  final Random _rnd = Random();

  @override
  void initState() {
    super.initState();
    _percent = widget.initialPercent.clamp(0, 100);

    _timer = Timer.periodic(widget.updateInterval, (_) {
      setState(() {
        int delta = _rnd.nextInt(3); // 0,1,2
        _percent -= delta;
        if (_percent <= 5) {
          _percent = 100; // fake recharge
        }
      });
      if (widget.onChanged != null) widget.onChanged!(_percent);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Color _batteryColor(int percent) {
    if (percent >= 60) return Colors.green;
    if (percent >= 30) return Colors.amber;
    return Colors.red;
  }

  // The horizontal battery body UI (kept local to the widget)
  Widget _horizontalBattery(int percent) {
    const double bodyWidth = 30;
    const double bodyHeight = 18;
    const double capWidth = 6;
    const double capOverlap = 1.5;
    final double innerPadding = 3;
    final double fillMaxWidth = bodyWidth - innerPadding * 2;
    final double fillWidth = (percent.clamp(0, 100) / 100) * fillMaxWidth;
    final double totalWidth = bodyWidth + capWidth - capOverlap;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: totalWidth,
          height: bodyHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                top: 0,
                child: Container(
                  width: bodyWidth,
                  height: bodyHeight,
                  padding: EdgeInsets.all(innerPadding),
                  decoration: BoxDecoration(
                    border: Border.all(color: Pallet.font1, width: 1.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Stack(
                    children: [
                      Container(),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: fillWidth,
                          height: bodyHeight - innerPadding * 2,
                          decoration: BoxDecoration(
                            color: _batteryColor(percent),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: bodyWidth - capOverlap,
                top: (bodyHeight - (bodyHeight * 0.6)) / 2,
                child: Container(
                  width: capWidth,
                  height: bodyHeight * 0.6,
                  decoration: BoxDecoration(
                    color: Pallet.font1,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$percent%',
          style: GoogleFonts.spaceGrotesk(
            color: Pallet.font1,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return _horizontalBattery(_percent);
  }
}

class TimeWidget extends StatefulWidget {
  // optional style override
  final TextStyle? style;

  const TimeWidget({Key? key, this.style}) : super(key: key);

  @override
  State<TimeWidget> createState() => _TimeWidgetState();
}

class _TimeWidgetState extends State<TimeWidget> {
  Timer? _timer;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    // update once a second (keeps minute display in sync)
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _twoDigits(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final style =
        widget.style ??
        GoogleFonts.spaceGrotesk(
          color: Pallet.font1,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        );

    final hour = _twoDigits(_now.hour);
    final minute = _twoDigits(_now.minute);

    return Text('$hour:$minute', style: style);
  }
}
