import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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

  /// Start scanning for devices (filtered for e-bike or general scan)
  Future<void> startScan({Duration timeout = const Duration(seconds: 12)}) async {
    // Check adapter availability
    final isSupported = await FlutterBluePlus.isSupported;
    if (!isSupported) {
      debugPrint("Bluetooth not supported on this device");
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
      await FlutterBluePlus.startScan(
        timeout: timeout,
        androidUsesFineLocation: false,
      );
    } catch (e) {
      debugPrint("Error starting BLE scan: $e");
    }
  }

  /// Fetch devices already paired/bonded with Android
  Future<List<BluetoothDevice>> getBondedDevices() async {
    try {
      return await FlutterBluePlus.bondedDevices;
    } catch (e) {
      debugPrint("Error fetching bonded devices: $e");
      return [];
    }
  }

  /// Fetch devices connected to the Android system
  Future<List<BluetoothDevice>> getSystemDevices() async {
    try {
      return await FlutterBluePlus.systemDevices([]);
    } catch (e) {
      debugPrint("Error fetching system devices: $e");
      return [];
    }
  }

  /// Stop active scan
  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  /// Connect & pair with a selected device (e.g. Raspberry Pi 4B)
  Future<bool> connect(BluetoothDevice device) async {
    try {
      await stopScan();
      _connectedDevice = device;

      // Monitor connection state
      _connSub?.cancel();
      _connSub = device.connectionState.listen((state) {
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
      } catch (e) {
        debugPrint("Direct connect timed out ($e), retrying with autoConnect...");
        await device.connect(
          timeout: const Duration(seconds: 12),
          autoConnect: true,
        );
      }

      // Attempt pairing/bonding on Android only if not already bonded
      try {
        if (defaultTargetPlatform == TargetPlatform.android) {
          final bondedList = await FlutterBluePlus.bondedDevices;
          final isAlreadyBonded = bondedList.any((d) => d.remoteId == device.remoteId);
          if (!isAlreadyBonded) {
            await device.createBond();
          }
        }
      } catch (e) {
        debugPrint("Bonding notice: $e");
      }

      // Discover GATT services first
      await _discoverEbikeServices(device);

      // Request larger MTU on Android for large JSON packets (e.g. navigation destinations)
      try {
        if (defaultTargetPlatform == TargetPlatform.android) {
          final mtu = await device.requestMtu(512);
          debugPrint("Negotiated BLE MTU: $mtu");
        }
      } catch (e) {
        debugPrint("MTU request notice: $e");
      }

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
      debugPrint("Error connecting to ${device.remoteId}: $e");
      _cleanUpConnection();
      return false;
    }
  }

  bool _uuidEquals(Guid a, String b) {
    return a.toString().replaceAll('-', '').toLowerCase() ==
        b.replaceAll('-', '').toLowerCase();
  }

  /// Discover and cache E-Bike telemetry & control characteristics
  Future<bool> _discoverEbikeServices(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      for (final service in services) {
        if (_uuidEquals(service.uuid, ebikeServiceUuid)) {
          for (final char in service.characteristics) {
            if (_uuidEquals(char.uuid, telemetryCharUuid)) {
              try {
                await char.setNotifyValue(true);
                _telemetrySub?.cancel();
                _telemetrySub = char.lastValueStream.listen(_onTelemetryBytesReceived);
                final initial = await char.read();
                _onTelemetryBytesReceived(initial);
              } catch (_) {}
            } else if (_uuidEquals(char.uuid, controlCharUuid)) {
              _controlChar = char;
              debugPrint("Control characteristic found & cached: ${char.uuid}");
            }
          }
        }
      }
      return _controlChar != null;
    } catch (e) {
      debugPrint("Error discovering E-Bike services: $e");
      return false;
    }
  }

  /// Disconnect current device
  Future<void> disconnect() async {
    try {
      await _connectedDevice?.disconnect();
    } catch (_) {}
    _cleanUpConnection();
  }

  void _cleanUpConnection() {
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
      debugPrint("Error parsing telemetry JSON: $e");
    }
  }

  /// Send a control command to Raspberry Pi Host (set_mode, set_lock, set_lights, open_map)
  Future<bool> sendControlCommand(String action, dynamic value) async {
    // 1. If control characteristic not cached, attempt discovery
    if (_controlChar == null) {
      debugPrint("Control characteristic not cached, attempting discovery...");
      if (_connectedDevice != null) {
        await _discoverEbikeServices(_connectedDevice!);
      } else {
        final bonded = await getBondedDevices();
        for (final d in bonded) {
          if (d.isConnected) {
            _connectedDevice = d;
            await _discoverEbikeServices(d);
            break;
          }
        }
      }
    }

    if (_controlChar == null) {
      debugPrint("Control characteristic still not available");
      return false;
    }

    // 2. Format payload with trailing newline delimiter for streaming reassembly
    final payload = '${jsonEncode({
      "action": action,
      "val": value,
    })}\n';
    final bytes = utf8.encode(payload);

    // 3. Determine safe chunk size (default 20 bytes for standard BLE ATT MTU)
    int chunkSize = 20;
    try {
      final currentMtu = _connectedDevice?.mtuNow ?? 23;
      if (currentMtu > 25) {
        chunkSize = (currentMtu - 5).clamp(20, 240);
      }
    } catch (_) {}

    try {
      if (bytes.length <= chunkSize) {
        return await _writePacket(_controlChar!, bytes);
      } else {
        // Send in chunks of safe size to prevent GATT_INVALID_ATTRIBUTE_LENGTH
        for (int i = 0; i < bytes.length; i += chunkSize) {
          final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
          final chunk = bytes.sublist(i, end);
          final ok = await _writePacket(_controlChar!, chunk);
          if (!ok) {
            debugPrint("Failed writing chunk at index $i/${bytes.length}");
            return false;
          }
          // Small 20ms pacing between packets to prevent BLE buffer congestion
          await Future.delayed(const Duration(milliseconds: 20));
        }
        return true;
      }
    } catch (e) {
      debugPrint("sendControlCommand unexpected error: $e");
      return false;
    }
  }

  Future<bool> _writePacket(BluetoothCharacteristic char, List<int> chunk) async {
    try {
      await char.write(chunk, withoutResponse: false);
      return true;
    } catch (e) {
      try {
        await char.write(chunk, withoutResponse: true);
        return true;
      } catch (e2) {
        debugPrint("Write chunk failed (both modes): $e2");
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

  /// Send searched map destination to paired E-Bike display
  Future<bool> sendMapLocation({
    required String name,
    required String address,
    required double lat,
    required double lon,
    String? distance,
    String? duration,
  }) {
    // Keep name concise (max 30 chars) and address short (max 40 chars)
    final cleanName = name.length > 30 ? name.substring(0, 30) : name;
    final cleanAddress = address.length > 40 ? address.substring(0, 40) : address;

    // Round lat/lon to 5 decimals (approx 1 meter precision)
    final double cleanLat = double.parse(lat.toStringAsFixed(5));
    final double cleanLon = double.parse(lon.toStringAsFixed(5));

    return sendControlCommand('open_map', {
      'name': cleanName,
      'address': cleanAddress,
      'lat': cleanLat,
      'lon': cleanLon,
      'dist': ?distance,
      'dur': ?duration,
    });
  }
}
