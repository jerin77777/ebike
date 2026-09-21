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
  Future<void> startScan({Duration timeout = const Duration(seconds: 8)}) async {
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

    await FlutterBluePlus.startScan(
      timeout: timeout,
      androidUsesFineLocation: true,
    );
  }

  /// Stop active scan
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
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

      // Connect with autoConnect enabled for resilient pairing
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      // Attempt pairing/bonding on Android if supported
      try {
        if (defaultTargetPlatform == TargetPlatform.android) {
          await device.createBond();
        }
      } catch (e) {
        debugPrint("Bonding notice: $e");
      }

      // Discover GATT services
      final services = await device.discoverServices();
      for (final service in services) {
        if (service.uuid.toString().toLowerCase() == ebikeServiceUuid.toLowerCase()) {
          for (final char in service.characteristics) {
            final uuidStr = char.uuid.toString().toLowerCase();
            if (uuidStr == telemetryCharUuid.toLowerCase()) {
              // Subscribe to live telemetry notifications
              await char.setNotifyValue(true);
              _telemetrySub?.cancel();
              _telemetrySub = char.lastValueStream.listen(_onTelemetryBytesReceived);
              // Read initial value
              try {
                final initial = await char.read();
                _onTelemetryBytesReceived(initial);
              } catch (_) {}
            } else if (uuidStr == controlCharUuid.toLowerCase()) {
              _controlChar = char;
            }
          }
        }
      }

      // Send phone handshake so e-bike display immediately knows phone is connected
      if (_controlChar != null) {
        try {
          final phoneName = device.platformName.isNotEmpty ? device.platformName : 'Phone';
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

  /// Send a control command to Raspberry Pi Host (set_mode, set_lock, set_lights)
  Future<bool> sendControlCommand(String action, dynamic value) async {
    if (_controlChar == null) {
      debugPrint("Control characteristic not available");
      return false;
    }

    try {
      final payload = jsonEncode({
        "action": action,
        "val": value,
      });
      await _controlChar!.write(utf8.encode(payload), withoutResponse: false);
      return true;
    } catch (e) {
      debugPrint("Failed to write control command: $e");
      return false;
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
    return sendControlCommand('open_map', {
      'name': name,
      'address': address,
      'lat': lat,
      'lon': lon,
      'dist': ?distance,
      'dur': ?duration,
    });
  }
}
