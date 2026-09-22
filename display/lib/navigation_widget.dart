import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'globals.dart';
import 'offline_tile_provider.dart';
import 'raspberrypi.dart';

/// Fullscreen Navigation Widget for E-Bike Display (1024x680)
/// Displays the searched map location from the phone via OpenStreetMap,
/// with an automotive HUD banner, floating speed gauge, and touch controls.
class EbikeNavigationWidget extends StatefulWidget {
  final MapDestination destination;
  final VoidCallback onClose;
  final bool isEmbedded;

  const EbikeNavigationWidget({
    super.key,
    required this.destination,
    required this.onClose,
    this.isEmbedded = false,
  });

  @override
  State<EbikeNavigationWidget> createState() => _EbikeNavigationWidgetState();
}

class _EbikeNavigationWidgetState extends State<EbikeNavigationWidget>
    with SingleTickerProviderStateMixin {
  late final MapController _mapController;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  StreamSubscription<double>? _speedSub;
  double _currentSpeed = 0.0;
  double _currentZoom = 15.0;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Subscribe to live speed to show in the corner
    try {
      _speedSub = speedController.stream.listen((val) {
        if (mounted) {
          setState(() => _currentSpeed = val);
        }
      });
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant EbikeNavigationWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destination.lat != widget.destination.lat ||
        oldWidget.destination.lon != widget.destination.lon) {
      final newCenter = LatLng(widget.destination.lat, widget.destination.lon);
      _mapController.move(newCenter, 15.0);
    }
  }

  @override
  void dispose() {
    _speedSub?.cancel();
    _pulseController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  void _recenter() {
    final center = LatLng(widget.destination.lat, widget.destination.lon);
    _mapController.move(center, 15.0);
  }

  void _zoomIn() {
    _currentZoom = (_currentZoom + 1).clamp(10.0, 18.0);
    _mapController.move(_mapController.camera.center, _currentZoom);
  }

  void _zoomOut() {
    _currentZoom = (_currentZoom - 1).clamp(10.0, 18.0);
    _mapController.move(_mapController.camera.center, _currentZoom);
  }

  @override
  Widget build(BuildContext context) {
    final destLatLng = LatLng(widget.destination.lat, widget.destination.lon);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Interactive Coimbatore Offline Map Layer
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: destLatLng,
              initialZoom: _currentZoom,
              minZoom: 10.0,
              maxZoom: 18.0,
              backgroundColor: const Color(0xFF14171F),
            ),
            children: [
              TileLayer(
                tileProvider: CoimbatoreOfflineTileProvider(
                  enableNetworkFallback: false,
                ),
                minNativeZoom: 10,
                maxNativeZoom: 15,
                minZoom: 10.0,
                maxZoom: 18.0,
                tileBuilder: (context, tileWidget, tile) {
                  // Invert/dim tiles slightly for high-contrast e-bike dark mode
                  return ColorFiltered(
                    colorFilter: const ColorFilter.matrix(<double>[
                      0.85, 0, 0, 0, -20, // red
                      0, 0.85, 0, 0, -20, // green
                      0, 0, 0.95, 0, -10, // blue
                      0, 0, 0, 1, 0,       // alpha
                    ]),
                    child: tileWidget,
                  );
                },
              ),

              // Destination Marker with animated pulsing ring
              MarkerLayer(
                markers: [
                  Marker(
                    point: destLatLng,
                    width: 70,
                    height: 70,
                    child: AnimatedBuilder(
                      animation: _pulseAnimation,
                      builder: (context, child) {
                        return Transform.scale(
                          scale: _pulseAnimation.value,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFF0066FF).withValues(alpha: 0.3),
                                ),
                              ),
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFF0066FF),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF0066FF).withValues(alpha: 0.6),
                                      blurRadius: 12,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.navigation,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),

          // 2. Top HUD Navigation Card
          Positioned(
            top: widget.isEmbedded ? 10 : 14,
            left: widget.isEmbedded ? 10 : 14,
            right: widget.isEmbedded ? 10 : 14,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: widget.isEmbedded ? 12 : 18,
                vertical: widget.isEmbedded ? 10 : 14,
              ),
              decoration: BoxDecoration(
                color: const Color(0xDD0D111A),
                borderRadius: BorderRadius.circular(widget.isEmbedded ? 16 : 20),
                border: Border.all(color: const Color(0xFF2A364F), width: 1.5),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Phone / Bluetooth Connected Icon
                  Container(
                    padding: EdgeInsets.all(widget.isEmbedded ? 8 : 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0066FF).withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF0066FF).withValues(alpha: 0.5),
                      ),
                    ),
                    child: Icon(
                      Icons.near_me_rounded,
                      color: const Color(0xFF3399FF),
                      size: widget.isEmbedded ? 20 : 26,
                    ),
                  ),
                  SizedBox(width: widget.isEmbedded ? 10 : 14),

                  // Destination Details
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Builder(
                              builder: (context) {
                                final isSynced = widget.destination.name != 'Coimbatore City' &&
                                    (widget.destination.distance != null ||
                                        BluetoothState.currentStatus == BtConnectionState.connected);
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSynced
                                        ? Colors.green.withValues(alpha: 0.2)
                                        : const Color(0xFF00E5FF).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isSynced
                                          ? Colors.green.withValues(alpha: 0.5)
                                          : const Color(0xFF00E5FF).withValues(alpha: 0.5),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        isSynced ? Icons.bluetooth : Icons.offline_pin_rounded,
                                        size: 12,
                                        color: isSynced ? Colors.greenAccent : const Color(0xFF00E5FF),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        isSynced ? 'LIVE NAV' : 'OFFLINE MAP',
                                        style: TextStyle(
                                          color: isSynced ? Colors.greenAccent : const Color(0xFF00E5FF),
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            if (widget.destination.distance != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                widget.destination.distance!,
                                style: const TextStyle(
                                  color: Color(0xFF33B5E5),
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                            if (widget.destination.duration != null) ...[
                              const SizedBox(width: 6),
                              Text(
                                '• ${widget.destination.duration!}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.destination.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: widget.isEmbedded ? 15 : 18,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.3,
                          ),
                        ),
                        if (widget.destination.address.isNotEmpty && !widget.isEmbedded) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.destination.address,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Close / Dashboard Button
                  if (!widget.isEmbedded)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white12,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: const BorderSide(color: Colors.white24),
                        ),
                      ),
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.speed, size: 18, color: Colors.white70),
                      label: const Text(
                        'Dashboard [M]',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    )
                  else
                    Material(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: widget.onClose,
                        child: const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Icon(Icons.close, size: 18, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // 3. Floating Speedometer Mini-HUD (Bottom-Left) - Only when full screen
          if (!widget.isEmbedded)
            Positioned(
              left: 16,
              bottom: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xDD0D111A),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF2A364F), width: 1.5),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      _currentSpeed.toStringAsFixed(0),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'MPH',
                      style: TextStyle(
                        color: Color(0xFF3399FF),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 4. Map Navigation Touch Controls (Bottom-Right)
          Positioned(
            right: widget.isEmbedded ? 10 : 16,
            bottom: widget.isEmbedded ? 10 : 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildMapControlBtn(
                  icon: Icons.my_location,
                  onTap: _recenter,
                  tooltip: 'Recenter Destination',
                ),
                const SizedBox(height: 8),
                _buildMapControlBtn(
                  icon: Icons.add,
                  onTap: _zoomIn,
                  tooltip: 'Zoom In',
                ),
                const SizedBox(height: 8),
                _buildMapControlBtn(
                  icon: Icons.remove,
                  onTap: _zoomOut,
                  tooltip: 'Zoom Out',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapControlBtn({
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return Material(
      color: const Color(0xDD0D111A),
      borderRadius: BorderRadius.circular(14),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF2A364F)),
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
