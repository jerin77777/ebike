import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

class Pallet {
  static Color font1 = Colors.white;
}

enum BtConnectionState { disconnected, advertising, connected }

class BluetoothState {
  static final StreamController<BtConnectionState> statusController =
      StreamController<BtConnectionState>.broadcast();
  static final StreamController<String?> deviceNameController =
      StreamController<String?>.broadcast();
  static BtConnectionState currentStatus = BtConnectionState.disconnected;
  static String? connectedDevice;

  static void update(BtConnectionState status, [String? device]) {
    currentStatus = status;
    connectedDevice = device;
    statusController.add(status);
    deviceNameController.add(device);
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
        final isNowActive = checkRes.stdout.toString().trim() == 'active' ||
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