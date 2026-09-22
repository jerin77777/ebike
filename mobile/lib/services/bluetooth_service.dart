import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// -------------------------------------------------------------
// UUIDs (Matching Raspberry Pi 4B BLE Host Daemon)
// -------------------------------------------------------------
const String ebikeServiceUuid = "19b10000-e8f2-537e-4f6c-d104768a1214";
const String telemetryCharUuid = "19b10001-e8f2-537e-4f6c-d104768a1214";
const String controlCharUuid = "19b10002-e8f2-537e-4f6c-d104768a1214";

class EbikeTelemetry {
  final double speed;
  final String mode;
  final int modeId;
  final int battery;
  final int range;
  final bool locked;
  final String lights;
  final String indicator;
  final bool reverse;
  final double temp;

  const EbikeTelemetry({
    this.speed = 0.0,
    this.mode = 'Sport',
    this.modeId = 3,
    this.battery = 84,
    this.range = 68,
    this.locked = true,
    this.lights = 'low_beam',
    this.indicator = 'none',
    this.reverse = false,
    this.temp = 28.5,
  });

  factory EbikeTelemetry.fromJson(Map<String, dynamic> json) {
    return EbikeTelemetry(
      speed: (json['speed'] is num) ? (json['speed'] as num).toDouble() : 0.0,
      mode: json['mode']?.toString() ?? 'Sport',
      modeId: (json['mode_id'] is int) ? json['mode_id'] as int : 3,
      battery: (json['battery'] is num) ? (json['battery'] as num).toInt() : 84,
      range: (json['range'] is num) ? (json['range'] as num).toInt() : 68,
      locked: json['locked'] == true,
      lights: json['lights']?.toString() ?? 'low_beam',
      indicator: json['indicator']?.toString() ?? 'none',
      reverse: json['reverse'] == true,
      temp: (json['temp'] is num) ? (json['temp'] as num).toDouble() : 28.5,
    );
  }

  EbikeTelemetry copyWith({
    double? speed,
    String? mode,
    int? modeId,
    int? battery,
    int? range,
    bool? locked,
    String? lights,
    String? indicator,
    bool? reverse,
    double? temp,
  }) {
    return EbikeTelemetry(
      speed: speed ?? this.speed,
      mode: mode ?? this.mode,
      modeId: modeId ?? this.modeId,
      battery: battery ?? this.battery,
      range: range ?? this.range,
      locked: locked ?? this.locked,
      lights: lights ?? this.lights,
      indicator: indicator ?? this.indicator,
      reverse: reverse ?? this.reverse,
      temp: temp ?? this.temp,
    );
  }
}

class EbikeBluetoothService {
  static final EbikeBluetoothService instance = EbikeBluetoothService._internal();
  EbikeBluetoothService._internal();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _controlChar;

  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _telemetrySub;

  final StreamController<EbikeTelemetry> _telemetryController =
      StreamController<EbikeTelemetry>.broadcast();
  Stream<EbikeTelemetry> get telemetryStream => _telemetryController.stream;

  final StreamController<BluetoothConnectionState> _connectionStateController =
      StreamController<BluetoothConnectionState>.broadcast();
  Stream<BluetoothConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  EbikeTelemetry _currentTelemetry = const EbikeTelemetry();
  EbikeTelemetry get currentTelemetry => _currentTelemetry;

  BluetoothConnectionState _currentState = BluetoothConnectionState.disconnected;
  BluetoothConnectionState get currentState => _currentState;

  BluetoothDevice? get connectedDevice => _connectedDevice;
  bool get isConnected => _currentState == BluetoothConnectionState.connected;

  final List<String> bleLogs = [];
  String? lastError;

  void log(String msg) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    final line = '[$timestamp] [BLE] $msg';
    bleLogs.add(line);
    if (bleLogs.length > 200) bleLogs.removeAt(0);
    debugPrint(line);
    print(line);
  }

  bool _uuidMatches(dynamic guidOrString, String targetUuid) {
    final a = guidOrString.toString().replaceAll('-', '').toLowerCase();
    final b = targetUuid.replaceAll('-', '').toLowerCase();
    return a == b;
  }

  /// Start scanning for devices (filtered for e-bike or general scan)
  Future<void> startScan({Duration timeout = const Duration(seconds: 12)}) async {
    // Check adapter availability
    final isSupported = await FlutterBluePlus.isSupported;
    if (!isSupported) {
      log("Bluetooth not supported on this device");
      return;
    }

    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
    }

    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
      log("Starting BLE scan for e-bike (timeout: ${timeout.inSeconds}s)...");
      await FlutterBluePlus.startScan(
        timeout: timeout,
        androidUsesFineLocation: false,
      );
    } catch (e) {
      log("Error starting BLE scan: $e");
    }
  }

  /// Fetch devices already paired/bonded with Android
  Future<List<BluetoothDevice>> getBondedDevices() async {
    try {
      return await FlutterBluePlus.bondedDevices;
    } catch (e) {
      log("Error fetching bonded devices: $e");
      return [];
    }
  }

  /// Fetch devices currently connected to system Bluetooth
  Future<List<BluetoothDevice>> getSystemDevices() async {
    try {
      return await FlutterBluePlus.systemDevices([Guid.fromString(ebikeServiceUuid)]);
    } catch (e) {
      log("Error fetching system devices: $e");
      return [];
    }
  }

  /// Stop active scan
  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  /// Discover and cache E-Bike telemetry & control characteristics with full logging
  Future<bool> discoverEbikeServices(BluetoothDevice device) async {
    log("Discovering services on ${device.remoteId} (${device.platformName})...");
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await device.clearGattCache();
          log("Cleared Android GATT cache");
        } catch (e) {
          log("clearGattCache notice: $e");
        }
      }
      final services = await device.discoverServices();
      log("Discovered ${services.length} GATT services on ${device.platformName.isNotEmpty ? device.platformName : device.remoteId}");

      bool foundControl = false;
      bool foundTelemetry = false;

      // Primary Pass: Match expected 19b1... E-Bike custom GATT UUIDs
      for (final service in services) {
        log(" -> Service: ${service.uuid}");
        for (final char in service.characteristics) {
          log("    -> Char: ${char.uuid} [R:${char.properties.read}, W:${char.properties.write}, WNR:${char.properties.writeWithoutResponse}, N:${char.properties.notify}]");
          if (_uuidMatches(char.uuid, controlCharUuid)) {
            _controlChar = char;
            foundControl = true;
            log("    [OK] MATCHED E-Bike Control Characteristic: ${char.uuid}");
          }
          if (_uuidMatches(char.uuid, telemetryCharUuid)) {
            foundTelemetry = true;
            log("    [OK] MATCHED E-Bike Telemetry Characteristic: ${char.uuid}");
            try {
              if (char.properties.notify || char.properties.indicate) {
                await char.setNotifyValue(true);
                _telemetrySub?.cancel();
                _telemetrySub = char.lastValueStream.listen(_onTelemetryBytesReceived);
                final initial = await char.read();
                _onTelemetryBytesReceived(initial);
                log("    [OK] Subscribed to telemetry notifications");
              }
            } catch (e) {
              log("    Telemetry notification setup note: $e");
            }
          }
        }
      }

      if (!foundControl) {
        // Detect if only BlueZ default / MIDI services are present
        final hasMidi = services.any((s) => s.uuid.toString().toLowerCase().contains("03b80e5a"));
        if (hasMidi) {
          lastError = "Raspberry Pi BLE daemon is not running! Only default BlueZ MIDI service detected. Start 'ebike_bluetooth_host.py' on the Pi.";
        } else {
          lastError = "Control characteristic ($controlCharUuid) not found on ${device.platformName.isNotEmpty ? device.platformName : device.remoteId}";
        }
        log("[ERROR] $lastError");
      }
      if (!foundTelemetry) {
        log("[WARN] Telemetry characteristic ($telemetryCharUuid) not found on ${device.platformName.isNotEmpty ? device.platformName : device.remoteId}");
      }
      return foundControl;
    } catch (e) {
      lastError = "discoverServices error: $e";
      log("ERROR: $lastError");
      return false;
    }
  }

  /// Connect & pair with a selected device (e.g. Raspberry Pi 4B)
  Future<bool> connect(BluetoothDevice device) async {
    try {
      await stopScan();
      _connectedDevice = device;
      log("Initiating connect to ${device.remoteId} (${device.platformName})...");

      // Monitor connection state
      _connSub?.cancel();
      _connSub = device.connectionState.listen((state) {
        log("Connection state change: $state");
        _currentState = state;
        _connectionStateController.add(state);
        if (state == BluetoothConnectionState.disconnected) {
          _cleanUpConnection();
        }
      });

      // Connect with fallback retry for Android GATT 147 / timeout errors
      try {
        await device.connect(
          timeout: const Duration(seconds: 6),
          autoConnect: false,
        );
        log("Direct connect successful");
      } catch (e) {
        log("Direct connect timed out ($e), retrying with autoConnect: true...");
        await device.connect(
          timeout: const Duration(seconds: 12),
          autoConnect: true,
        );
        log("autoConnect connected");
      }

      // Attempt pairing/bonding on Android only if not already bonded
      try {
        if (defaultTargetPlatform == TargetPlatform.android) {
          final bondedList = await FlutterBluePlus.bondedDevices;
          final isAlreadyBonded = bondedList.any((d) => d.remoteId == device.remoteId);
          if (!isAlreadyBonded) {
            log("Creating bond with ${device.remoteId}...");
            await device.createBond();
          } else {
            log("Device already bonded");
          }
        }
      } catch (e) {
        log("Bonding notice: $e");
      }

      // Request larger MTU on Android for large JSON packets (e.g. navigation destinations)
      try {
        if (defaultTargetPlatform == TargetPlatform.android) {
          final mtu = await device.requestMtu(512);
          log("Negotiated BLE MTU: $mtu");
        }
      } catch (e) {
        log("MTU request notice: $e");
      }

      // Discover GATT services
      await discoverEbikeServices(device);

      // Send phone handshake so e-bike display immediately knows phone is connected
      if (_controlChar != null) {
        try {
          final phoneName = defaultTargetPlatform == TargetPlatform.android
              ? 'Android Phone'
              : (defaultTargetPlatform == TargetPlatform.iOS ? 'iPhone' : 'Mobile Device');
          await sendControlCommand('phone_connected', {
            'device_name': phoneName,
          });
        } catch (_) {}
      }

      return true;
    } catch (e) {
      lastError = "Connection error: $e";
      log("ERROR: $lastError");
      _cleanUpConnection();
      return false;
    }
  }

  /// Disconnect current device
  Future<void> disconnect() async {
    try {
      log("Disconnecting from ${_connectedDevice?.remoteId}...");
      await _connectedDevice?.disconnect();
    } catch (_) {}
    _cleanUpConnection();
  }

  void _cleanUpConnection() {
    log("Cleaning up Bluetooth connection state");
    _telemetrySub?.cancel();
    _telemetrySub = null;
    _controlChar = null;
    _connectedDevice = null;
    _currentState = BluetoothConnectionState.disconnected;
    _connectionStateController.add(_currentState);
  }

  void _onTelemetryBytesReceived(List<int> bytes) {
    if (bytes.isEmpty) return;
    try {
      final jsonStr = utf8.decode(bytes);
      final map = jsonDecode(jsonStr);
      if (map is Map<String, dynamic>) {
        _currentTelemetry = EbikeTelemetry.fromJson(map);
        _telemetryController.add(_currentTelemetry);
      }
    } catch (e) {
      log("Error parsing telemetry JSON: $e");
    }
  }

  /// Send a control command to Raspberry Pi Host (set_mode, set_lock, set_lights, open_map)
  Future<bool> sendControlCommand(String action, dynamic value) async {
    log(">>> sendControlCommand: '$action' triggered");

    // 1. Check or restore connected device
    if (_connectedDevice == null || !isConnected) {
      log("Device marked not connected (_currentState: $_currentState). Checking bonded devices...");
      final bonded = await getBondedDevices();
      for (final d in bonded) {
        if (d.isConnected) {
          _connectedDevice = d;
          _currentState = BluetoothConnectionState.connected;
          _connectionStateController.add(_currentState);
          log("Re-associated connected device: ${d.platformName} (${d.remoteId})");
          break;
        }
      }
    }

    if (_connectedDevice == null) {
      lastError = "E-Bike is not connected via Bluetooth";
      log("ERROR: $lastError");
      return false;
    }

    // 2. Discover control characteristic if null
    if (_controlChar == null) {
      log("Control characteristic is null, performing on-demand service discovery...");
      final ok = await discoverEbikeServices(_connectedDevice!);
      if (!ok || _controlChar == null) {
        lastError = "Control characteristic ($controlCharUuid) not found on ${_connectedDevice!.platformName.isNotEmpty ? _connectedDevice!.platformName : 'E-Bike'}";
        log("ERROR: $lastError");
        return false;
      }
    }

    final payload = jsonEncode({
      "action": action,
      "val": value,
    });
    final bytes = utf8.encode(payload);
    final mtu = _connectedDevice!.mtuNow;
    final maxSingle = (mtu > 5) ? (mtu - 5) : 20;

    log("Sending '$action': ${bytes.length} bytes (MTU now: $mtu, maxSingle: $maxSingle)");

    // 3. Attempt write with response
    try {
      await _controlChar!.write(bytes, withoutResponse: false);
      log("[SUCCESS] '$action' sent with response");
      lastError = null;
      return true;
    } catch (e) {
      log("Write withResponse failed: $e. Retrying withoutResponse: true...");
      // 4. Attempt write without response
      try {
        await _controlChar!.write(bytes, withoutResponse: true);
        log("[SUCCESS] '$action' sent withoutResponse");
        lastError = null;
        return true;
      } catch (e2) {
        log("Write withoutResponse failed: $e2");
        // 5. Fallback: chunked delivery if payload exceeds maxSingle
        if (bytes.length > maxSingle) {
          log("Attempting chunked delivery (${bytes.length} bytes in $maxSingle byte chunks)...");
          try {
            for (int i = 0; i < bytes.length; i += maxSingle) {
              final end = (i + maxSingle < bytes.length) ? i + maxSingle : bytes.length;
              final chunk = bytes.sublist(i, end);
              log("Sending chunk [${i + 1}-$end / ${bytes.length}] (${chunk.length} bytes)...");
              try {
                await _controlChar!.write(chunk, withoutResponse: false);
              } catch (_) {
                await _controlChar!.write(chunk, withoutResponse: true);
              }
              await Future.delayed(const Duration(milliseconds: 25));
            }
            log("[SUCCESS] All chunks of '$action' sent successfully");
            lastError = null;
            return true;
          } catch (e3) {
            lastError = "Chunk write error: $e3";
            log("ERROR: $lastError");
            return false;
          }
        }

        lastError = "Write failed: $e2";
        log("ERROR: $lastError");
        return false;
      }
    }
  }

  /// Convenience commands
  Future<bool> setRideMode(String mode) => sendControlCommand('set_mode', mode);
  Future<bool> setLockState(bool locked) => sendControlCommand('set_lock', locked);
  Future<bool> setLights(String mode) => sendControlCommand('set_lights', mode);

  /// Notify E-Bike display that phone is connected
  Future<void> notifyPhoneConnected([String? name]) async {
    if (_controlChar != null) {
      try {
        final phoneName = name ??
            (_connectedDevice?.platformName.isNotEmpty == true
                ? _connectedDevice!.platformName
                : 'Phone');
        await sendControlCommand('phone_connected', {
          'device_name': phoneName,
        });
      } catch (_) {}
    }
  }

  /// Send searched map destination and route to paired E-Bike display
  Future<bool> sendMapLocation({
    required String name,
    required String address,
    required double lat,
    required double lon,
    double? fromLat,
    double? fromLon,
    String? distance,
    String? duration,
    List<List<double>>? routePoints,
  }) {
    // Keep address compact to keep BLE payload small and reliable
    final cleanAddress = address.length > 60 ? address.substring(0, 60) : address;
    final Map<String, dynamic> payload = {
      'name': name,
      'address': cleanAddress,
      'lat': double.parse(lat.toStringAsFixed(6)),
      'lon': double.parse(lon.toStringAsFixed(6)),
    };
    if (fromLat != null) payload['from_lat'] = double.parse(fromLat.toStringAsFixed(6));
    if (fromLon != null) payload['from_lon'] = double.parse(fromLon.toStringAsFixed(6));
    if (distance != null) payload['dist'] = distance;
    if (duration != null) payload['dur'] = duration;
    if (routePoints != null && routePoints.isNotEmpty) {
      // Sample route to max ~35 points so it fits smoothly into BLE payload
      List<List<double>> sampled = [];
      if (routePoints.length <= 35) {
        sampled = routePoints.map((p) => [
          double.parse(p[0].toStringAsFixed(5)),
          double.parse(p[1].toStringAsFixed(5)),
        ]).toList();
      } else {
        final step = (routePoints.length / 30).ceil();
        for (int i = 0; i < routePoints.length; i += step) {
          sampled.add([
            double.parse(routePoints[i][0].toStringAsFixed(5)),
            double.parse(routePoints[i][1].toStringAsFixed(5)),
          ]);
        }
        if (sampled.last != routePoints.last) {
          sampled.add([
            double.parse(routePoints.last[0].toStringAsFixed(5)),
            double.parse(routePoints.last[1].toStringAsFixed(5)),
          ]);
        }
      }
      payload['route'] = sampled;
    }
    return sendControlCommand('open_map', payload);
  }

  /// Display live Bluetooth Logs modal dialog
  void showLogsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF161B26),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.receipt_long, color: Color(0xFF0066FF), size: 22),
              const SizedBox(width: 8),
              const Text(
                'Bluetooth Logs',
                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.copy, color: Colors.white70, size: 20),
                tooltip: 'Copy Logs',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: bleLogs.join('\n')));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Logs copied to clipboard!'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: bleLogs.isEmpty
                ? const Center(
                    child: Text('No BLE logs recorded yet', style: TextStyle(color: Colors.white54)),
                  )
                : Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0C1017),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: ListView.builder(
                      itemCount: bleLogs.length,
                      itemBuilder: (context, idx) {
                        final logText = bleLogs[idx];
                        final isErr = logText.contains('ERROR') || logText.contains('failed');
                        final isSuccess = logText.contains('[SUCCESS]') || logText.contains('[OK]');
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: SelectableText(
                            logText,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: isErr
                                  ? Colors.redAccent
                                  : (isSuccess ? Colors.greenAccent : Colors.white70),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                bleLogs.clear();
                Navigator.pop(ctx);
              },
              child: const Text('Clear', style: TextStyle(color: Colors.redAccent)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close', style: TextStyle(color: Color(0xFF0066FF))),
            ),
          ],
        );
      },
    );
  }
}
