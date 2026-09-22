import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'map_screen.dart';
import 'services/bluetooth_service.dart';
import 'widgets/bluetooth_modal.dart';

void main() {
  runApp(const EbikeMapApp());
}

class EbikeMapApp extends StatelessWidget {
  const EbikeMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Volt E-Bike',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0066FF),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6F9),
      ),
      home: const EbikeHomeScreen(),
    );
  }
}

class EbikeHomeScreen extends StatefulWidget {
  const EbikeHomeScreen({super.key});

  @override
  State<EbikeHomeScreen> createState() => _EbikeHomeScreenState();
}

class _EbikeHomeScreenState extends State<EbikeHomeScreen> {
  final EbikeBluetoothService _bt = EbikeBluetoothService.instance;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<EbikeTelemetry>? _telemetrySub;

  bool _isBtConnected = false;
  bool _isLocked = true;
  bool _lightsOn = false;
  String? _selectedMode;
  int? _batteryLevel;
  int? _rangeKm;
  double? _currentSpeed;
  double? _temperature;

  final List<Map<String, dynamic>> _rideModes = [
    {'name': 'Eco', 'icon': Icons.eco, 'color': Colors.green},
    {'name': 'City', 'icon': Icons.location_city, 'color': Colors.blue},
    {'name': 'Sport', 'icon': Icons.flash_on, 'color': Colors.orange},
    {'name': 'Turbo', 'icon': Icons.speed, 'color': Colors.redAccent},
  ];

  @override
  void initState() {
    super.initState();
    _isBtConnected = _bt.isConnected;

    // Listen to Bluetooth connection state
    _connSub = _bt.connectionStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isBtConnected = (state == BluetoothConnectionState.connected);
          if (!_isBtConnected) {
            _selectedMode = null;
            _batteryLevel = null;
            _rangeKm = null;
            _currentSpeed = null;
            _temperature = null;
          }
        });
      }
      if (state == BluetoothConnectionState.connected) {
        _bt.notifyPhoneConnected();
      }
    });

    // Listen to real-time telemetry from Raspberry Pi 4B
    _telemetrySub = _bt.telemetryStream.listen((data) {
      if (mounted) {
        setState(() {
          _currentSpeed = data.speed;
          _temperature = data.temp;
          _batteryLevel = data.battery;
          _rangeKm = data.range;
          _isLocked = data.locked;
          _lightsOn = (data.lights != 'none' && data.lights.isNotEmpty);

          // Sync selected mode with bike
          for (final m in _rideModes) {
            if (m['name'].toString().toLowerCase() == data.mode.toLowerCase()) {
              _selectedMode = m['name'];
            }
          }
          if (_selectedMode == null && data.mode.isNotEmpty) {
            _selectedMode = data.mode;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _telemetrySub?.cancel();
    super.dispose();
  }

  void _onModeSelected(String mode) {
    setState(() => _selectedMode = mode);
    if (_isBtConnected) {
      _bt.setRideMode(mode);
    }
  }

  void _toggleLock() {
    final next = !_isLocked;
    setState(() => _isLocked = next);
    if (_isBtConnected) {
      _bt.setLockState(next);
    }
  }

  void _toggleLights() {
    final next = !_lightsOn;
    setState(() => _lightsOn = next);
    if (_isBtConnected) {
      _bt.setLights(next ? 'high_beam' : 'none');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const primaryColor = Color(0xFF0066FF);

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF121212)
          : const Color(0xFFF4F6F9),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/horse.png', height: 50, fit: BoxFit.fitHeight),
            const SizedBox(width: 2),
            Image.asset('assets/name.png', width: 120, fit: BoxFit.fitWidth),
          ],
        ),
        actions: [
          // Bluetooth Connection & Pairing Pill
          GestureDetector(
            onTap: () => BluetoothModal.show(context),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _isBtConnected
                    ? Colors.green.withValues(alpha: 0.15)
                    : primaryColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isBtConnected
                      ? Colors.green.withValues(alpha: 0.6)
                      : primaryColor.withValues(alpha: 0.4),
                  width: 1.2,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isBtConnected
                        ? Icons.bluetooth_connected_rounded
                        : Icons.bluetooth_searching_rounded,
                    color: _isBtConnected ? Colors.green : primaryColor,
                    size: 16,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isBtConnected ? 'Connected' : 'Pair Pi',
                    style: TextStyle(
                      color: _isBtConnected ? Colors.green : primaryColor,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () {},
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // E-Bike Image Showcase
              Expanded(
                child: Center(
                  child: Image.asset(
                    'assets/ebike.png',
                    height: 180,
                    fit: BoxFit.fitHeight,
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Hero E-Bike Battery & Status Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isDark
                        ? [const Color(0xFF1E2640), const Color(0xFF0F172A)]
                        : [const Color(0xFF0066FF), const Color(0xFF0052CC)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withValues(alpha: 0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Battery Level',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text(
                                  _batteryLevel != null ? '$_batteryLevel%' : '--',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 40,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.bolt,
                                  color: Colors.amberAccent,
                                  size: 28,
                                ),
                              ],
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Column(
                            children: [
                              const Text(
                                'Est. Range',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _rangeKm != null ? '$_rangeKm km' : '--',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Battery progress bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: LinearProgressIndicator(
                        value: _batteryLevel != null
                            ? (_batteryLevel! / 100.0).clamp(0.0, 1.0)
                            : 0.0,
                        minHeight: 10,
                        backgroundColor: Colors.white24,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _batteryLevel != null ? Colors.greenAccent : Colors.white12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildQuickStatus(
                          _temperature != null
                              ? '${_temperature!.toStringAsFixed(1)}°C'
                              : '--',
                          'Temperature',
                          Icons.thermostat_rounded,
                        ),
                        _buildQuickStatus(
                          _selectedMode ?? '--',
                          'Ride Mode',
                          Icons.tune,
                        ),
                        _buildQuickStatus(
                          _isBtConnected ? 'Active' : 'Offline',
                          'BT Host Link',
                          Icons.bluetooth_connected,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // Remote Controls (Lock / Unlock & Headlights)

              // Open Maps & Navigation Action Card
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const MapScreen()),
                  );
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isDark
                          ? [const Color(0xFF242B3E), const Color(0xFF1A1F2C)]
                          : [Colors.white, const Color(0xFFF0F4FF)],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: primaryColor.withValues(alpha: 0.4),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: primaryColor,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: primaryColor.withValues(alpha: 0.4),
                              blurRadius: 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.map_rounded,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Text(
                                  'Maps & Navigation',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text(
                                    'GPS Live',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.green,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Open maps, search destinations & find charging spots',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? Colors.grey[400]
                                    : Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: primaryColor,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickStatus(String val, String label, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: Colors.white70, size: 20),
        const SizedBox(height: 4),
        Text(
          val,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 10),
        ),
      ],
    );
  }
}
