import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

class Pallet {
  static Color font1 = Colors.white;
}

bool debug = true;

enum BtConnectionState { disconnected, advertising, connected }

class BluetoothState {
  static final StreamController<BtConnectionState> statusController =
      StreamController<BtConnectionState>.broadcast();
  static final StreamController<String?> deviceNameController =
      StreamController<String?>.broadcast();
  static BtConnectionState currentStatus = BtConnectionState.disconnected;
  static String? connectedDevice;

  static Timer? _pollTimer;

  static void update(BtConnectionState status, [String? device]) {
    currentStatus = status;
    connectedDevice = device;
    statusController.add(status);
    deviceNameController.add(device);
  }

  /// Periodically polls BlueZ for any connected phone on Linux/Raspberry Pi
  static void startMonitoring() {
    if (!Platform.isLinux) return;
    _pollTimer?.cancel();
    _checkSystemBt();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _checkSystemBt());
  }

  static Future<void> _checkSystemBt() async {
    try {
      final res = await Process.run('bluetoothctl', ['devices', 'Connected']);
      final out = res.stdout.toString().trim();
      if (out.isNotEmpty) {
        // Output format: "Device XX:XX:XX:XX:XX:XX Name Of Device"
        final lines = out.split('\n');
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.startsWith('Device ')) {
            final parts = trimmed.split(' ');
            String phoneName = 'Phone';
            if (parts.length >= 3) {
              phoneName = parts.sublist(2).join(' ');
            }
            if (currentStatus != BtConnectionState.connected || connectedDevice != phoneName) {
              update(BtConnectionState.connected, phoneName);
            }
            return;
          }
        }
      } else {
        // If system reports no connected devices and we are currently marked connected:
        if (currentStatus == BtConnectionState.connected) {
          update(BtConnectionState.disconnected, null);
        }
      }
    } catch (_) {}
  }
}

class HostState {
  static final StreamController<bool> statusController =
      StreamController<bool>.broadcast();
  static bool isActive = false;
  static bool isTransitioning = false;

  static void update(bool active, {bool transitioning = false}) {
    isActive = active;
    isTransitioning = transitioning;
    statusController.add(active);
  }

  /// Toggle Host AP mode on/off
  static Future<void> toggle() async {
    if (isTransitioning) return;
    final nextState = !isActive;
    update(isActive, transitioning: true);

    if (Platform.isLinux) {
      try {
        final script = File('toggle_hotspot.sh').existsSync()
            ? 'toggle_hotspot.sh'
            : (File('display/toggle_hotspot.sh').existsSync()
                  ? 'display/toggle_hotspot.sh'
                  : '/home/ebike/ebike/display/toggle_hotspot.sh');

        final action = nextState ? 'on' : 'off';
        final res = await Process.run('bash', [script, action]);
        if (res.exitCode != 0) {
          debugPrint('Hotspot $action stderr: ${res.stderr}');
        }
        final checkRes = await Process.run('bash', [script, 'status']);
        final isNowActive =
            checkRes.stdout.toString().trim() == 'active' ||
            (res.exitCode == 0 && nextState);
        update(isNowActive, transitioning: false);
      } catch (e) {
        debugPrint('Hotspot toggle error: $e');
        update(nextState, transitioning: false);
      }
    } else {
      // Simulation for development on non-Linux platforms
      await Future.delayed(const Duration(milliseconds: 600));
      update(nextState, transitioning: false);
    }
  }

  /// Check initial Host AP status
  static Future<void> checkInitialStatus() async {
    if (!Platform.isLinux) return;
    try {
      final script = File('toggle_hotspot.sh').existsSync()
          ? 'toggle_hotspot.sh'
          : (File('display/toggle_hotspot.sh').existsSync()
                ? 'display/toggle_hotspot.sh'
                : '/home/ebike/ebike/display/toggle_hotspot.sh');

      final res = await Process.run('bash', [script, 'status']);
      final isNowActive = res.stdout.toString().trim() == 'active';
      update(isNowActive, transitioning: false);
    } catch (e) {
      debugPrint('Hotspot initial check error: $e');
    }
  }
}

class MapDestination {
  final String name;
  final String address;
  final double lat;
  final double lon;
  final String? distance;
  final String? duration;

  const MapDestination({
    required this.name,
    required this.address,
    required this.lat,
    required this.lon,
    this.distance,
    this.duration,
  });

  factory MapDestination.fromDynamic(dynamic raw) {
    if (raw is! Map) {
      return const MapDestination(
        name: 'Selected Destination',
        address: '',
        lat: 0.0,
        lon: 0.0,
      );
    }
    final map = Map<String, dynamic>.from(raw);
    return MapDestination(
      name: map['name']?.toString() ?? 'Destination',
      address: map['address']?.toString() ?? '',
      lat: (map['lat'] is num)
          ? (map['lat'] as num).toDouble()
          : double.tryParse(map['lat']?.toString() ?? '') ?? 0.0,
      lon: (map['lon'] is num)
          ? (map['lon'] as num).toDouble()
          : double.tryParse(map['lon']?.toString() ?? '') ?? 0.0,
      distance: map['dist']?.toString() ?? map['distance']?.toString(),
      duration: map['dur']?.toString() ?? map['duration']?.toString(),
    );
  }
}

class NavigationState {
  static const MapDestination defaultCoimbatore = MapDestination(
    name: 'Coimbatore City',
    address: 'Tamil Nadu, India',
    lat: 11.0168,
    lon: 76.9558,
  );

  static final StreamController<MapDestination?> destinationController =
      StreamController<MapDestination?>.broadcast();
  static final StreamController<bool> activeController =
      StreamController<bool>.broadcast();

  static MapDestination? currentDestination;
  static bool isNavigating = false;

  static void openMap([MapDestination? destination]) {
    currentDestination = destination ?? defaultCoimbatore;
    isNavigating = true;
    destinationController.add(currentDestination);
    activeController.add(true);
  }

  static void closeMap() {
    isNavigating = false;
    activeController.add(false);
  }

  static void toggle() {
    if (isNavigating) {
      closeMap();
    } else {
      openMap(currentDestination ?? defaultCoimbatore);
    }
  }
}

class TemperatureState {
  static double currentTemp = 37.0;
  static final StreamController<double> tempController =
      StreamController<double>.broadcast();

  static void update(double temp) {
    currentTemp = temp;
    tempController.add(temp);
  }

  /// Reads actual Raspberry Pi hardware SoC temperature or provides fallback
  static double readHardwareTemp() {
    try {
      final f = File('/sys/class/thermal/thermal_zone0/temp');
      if (f.existsSync()) {
        final raw = f.readAsStringSync().trim();
        final val = double.tryParse(raw);
        if (val != null && val > 0) {
          final deg = (val / 1000.0 * 10).round() / 10.0;
          currentTemp = deg;
          return deg;
        }
      }
    } catch (_) {}
    return currentTemp;
  }
}
