import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/bluetooth_service.dart';

class BluetoothModal extends StatefulWidget {
  const BluetoothModal({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const BluetoothModal(),
    );
  }

  @override
  State<BluetoothModal> createState() => _BluetoothModalState();
}

class _BluetoothModalState extends State<BluetoothModal>
    with SingleTickerProviderStateMixin {
  final EbikeBluetoothService _bt = EbikeBluetoothService.instance;
  List<ScanResult> _scanResults = [];
  List<BluetoothDevice> _bondedDevices = [];
  bool _isScanning = false;
  bool _onlyShowEbike = true;
  String? _connectingDeviceId;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _isScanningSub;
  late AnimationController _radarController;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _loadBondedDevices();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (mounted) {
        setState(() {
          // Sort results so Volt-EBike-RPI4 appears at the very top
          results.sort((a, b) {
            final aIsEbike = _isEbikeDevice(a);
            final bIsEbike = _isEbikeDevice(b);
            if (aIsEbike && !bIsEbike) return -1;
            if (!aIsEbike && bIsEbike) return 1;
            return b.rssi.compareTo(a.rssi);
          });
          _scanResults = results;
        });
      }
    });

    _isScanningSub = FlutterBluePlus.isScanning.listen((scanning) {
      if (mounted) setState(() => _isScanning = scanning);
    });

    // Start scan on open if not already connected
    if (!_bt.isConnected) {
      _startScan();
    }
  }

  Future<void> _loadBondedDevices() async {
    final bonded = await _bt.getBondedDevices();
    final system = await _bt.getSystemDevices();
    final combined = <String, BluetoothDevice>{};
    for (final d in [...bonded, ...system]) {
      combined[d.remoteId.str] = d;
    }
    if (mounted) {
      setState(() {
        _bondedDevices = combined.values.toList();
      });
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _isScanningSub?.cancel();
    _radarController.dispose();
    super.dispose();
  }

  void _startScan() {
    setState(() => _scanResults = []);
    _loadBondedDevices();
    _bt.startScan();
  }

  bool _isEbikeName(String name) {
    if (name.isEmpty) return false;
    final n = name.toLowerCase().replaceAll('-', '').replaceAll('_', '').replaceAll(' ', '');
    return n.contains('volt') ||
        n.contains('ebike') ||
        n.contains('rpi') ||
        n.contains('raspberry') ||
        n.contains('bike');
  }

  bool _isEbikeDevice(ScanResult result) {
    final hasServiceUuid = result.advertisementData.serviceUuids.any(
      (uuid) => uuid.toString().toLowerCase() == ebikeServiceUuid.toLowerCase(),
    );
    final name = result.device.platformName;
    final advName = result.advertisementData.advName;
    return hasServiceUuid || _isEbikeName(name) || _isEbikeName(advName);
  }

  bool _isEbikeBonded(BluetoothDevice dev) {
    return _isEbikeName(dev.platformName);
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() => _connectingDeviceId = device.remoteId.str);
    final success = await _bt.connect(device);
    if (mounted) {
      setState(() => _connectingDeviceId = null);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF0066FF),
            content: Text("Connected & paired with ${device.platformName.isNotEmpty ? device.platformName : 'Raspberry Pi 4B'}!"),
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text("Connection failed. Ensure Raspberry Pi Bluetooth daemon is running."),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _disconnect() async {
    await _bt.disconnect();
    if (mounted) {
      setState(() {});
      _startScan();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = const Color(0xFF0066FF);

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2230) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Column(
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.bluetooth_searching_rounded, color: primaryColor, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Bluetooth Pairing",
                          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          _bt.isConnected
                              ? "Connected to Host"
                              : (_isScanning ? "Scanning for Raspberry Pi..." : "Idle"),
                          style: TextStyle(
                            fontSize: 12,
                            color: _bt.isConnected
                                ? Colors.green
                                : (_isScanning ? primaryColor : Colors.grey),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (!_bt.isConnected)
                  IconButton(
                    icon: _isScanning
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: primaryColor),
                          )
                        : Icon(Icons.refresh_rounded, color: primaryColor),
                    onPressed: _isScanning ? null : _startScan,
                  ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Content Body
          Expanded(
            child: _bt.isConnected
                ? _buildConnectedView(isDark, primaryColor)
                : _buildScanningView(isDark, primaryColor),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedView(bool isDark, Color primaryColor) {
    final dev = _bt.connectedDevice;
    final name = (dev?.platformName.isNotEmpty == true) ? dev!.platformName : 'Volt-EBike-RPI4 (Raspberry Pi)';

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.green.withValues(alpha: 0.3), width: 2),
            ),
            child: const Icon(
              Icons.bluetooth_connected_rounded,
              size: 64,
              color: Colors.green,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            name,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            "Device ID: ${dev?.remoteId.str ?? 'Unknown'}",
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.check_circle_rounded, color: Colors.green, size: 16),
                SizedBox(width: 6),
                Text(
                  "Paired & Telemetry Active",
                  style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ],
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.withValues(alpha: 0.12),
                foregroundColor: Colors.redAccent,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: Colors.redAccent),
                ),
              ),
              icon: const Icon(Icons.link_off_rounded),
              label: const Text("Disconnect Device", style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: _disconnect,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanningView(bool isDark, Color primaryColor) {
    final ebikeResults = _scanResults.where(_isEbikeDevice).toList();
    final visibleScanResults = _onlyShowEbike ? ebikeResults : _scanResults;
    final otherCount = _scanResults.length - ebikeResults.length;

    final ebikeBonded = _bondedDevices.where(_isEbikeBonded).toList();
    final visibleBonded = _onlyShowEbike ? ebikeBonded : _bondedDevices;

    final hasAnyVisible = visibleBonded.isNotEmpty || visibleScanResults.isNotEmpty;

    if (!hasAnyVisible) {
      final totalHidden = (_scanResults.length - visibleScanResults.length) +
          (_bondedDevices.length - visibleBonded.length);

      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isScanning) ...[
                Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _radarController,
                      builder: (context, child) {
                        return Container(
                          width: 90 + (_radarController.value * 50),
                          height: 90 + (_radarController.value * 50),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: primaryColor.withValues(alpha: 1.0 - _radarController.value),
                              width: 2,
                            ),
                          ),
                        );
                      },
                    ),
                    Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.pedal_bike_rounded, size: 36, color: primaryColor),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const Text(
                  "Searching for Volt E-Bike...",
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  "Looking for 'Volt-EBike-RPI4' dashboard host...",
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  textAlign: TextAlign.center,
                ),
                if (_onlyShowEbike && totalHidden > 0) ...[
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () => setState(() => _onlyShowEbike = false),
                    icon: const Icon(Icons.tune_rounded, size: 16),
                    label: Text(
                      "$totalHidden device${totalHidden > 1 ? 's' : ''} found • Show all",
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ] else ...[
                Icon(Icons.pedal_bike_rounded, size: 56, color: Colors.grey[400]),
                const SizedBox(height: 16),
                const Text(
                  "No Volt E-Bike Found",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  "Ensure your bike's display is turned on and Bluetooth daemon is running.",
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text("Scan Again"),
                      onPressed: _startScan,
                    ),
                    if (_onlyShowEbike && totalHidden > 0) ...[
                      const SizedBox(width: 8),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () => setState(() => _onlyShowEbike = false),
                        child: Text("Show All ($totalHidden)"),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }

    final totalFound = visibleBonded.length + visibleScanResults.length;

    return Column(
      children: [
        // Filter bar / status indicator
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    _onlyShowEbike ? Icons.verified_rounded : Icons.devices_other_rounded,
                    size: 15,
                    color: _onlyShowEbike ? Colors.green : Colors.grey[600],
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _onlyShowEbike
                        ? "Showing E-Bike hardware only"
                        : "Showing all Bluetooth devices ($totalFound)",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _onlyShowEbike ? (isDark ? Colors.greenAccent : Colors.green[700]) : Colors.grey[600],
                    ),
                  ),
                ],
              ),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                onPressed: () => setState(() => _onlyShowEbike = !_onlyShowEbike),
                child: Text(
                  _onlyShowEbike ? "Show All" : "E-Bike Only",
                  style: TextStyle(fontSize: 12, color: primaryColor, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              // 1. Paired Devices (from phone settings)
              if (visibleBonded.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 6, top: 4),
                  child: Text(
                    "PAIRED IN PHONE SETTINGS",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: isDark ? Colors.white54 : Colors.grey[600],
                    ),
                  ),
                ),
                ...visibleBonded.map((dev) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildBondedDeviceTile(dev, isDark, primaryColor),
                    )),
                if (visibleScanResults.isNotEmpty) const SizedBox(height: 8),
              ],

              // 2. Discovered Devices (live scan)
              if (visibleScanResults.isNotEmpty) ...[
                if (visibleBonded.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 6, top: 4),
                    child: Text(
                      "DISCOVERED NEARBY",
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: isDark ? Colors.white54 : Colors.grey[600],
                      ),
                    ),
                  ),
                ...visibleScanResults.map((result) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildScanResultTile(result, isDark, primaryColor),
                    )),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBondedDeviceTile(BluetoothDevice dev, bool isDark, Color primaryColor) {
    final isEbike = _isEbikeBonded(dev);
    final displayName = dev.platformName.isNotEmpty ? dev.platformName : 'Volt-EBike-RPI4';
    final isConnectingThis = _connectingDeviceId == dev.remoteId.str;

    return Container(
      decoration: BoxDecoration(
        color: isEbike
            ? primaryColor.withValues(alpha: isDark ? 0.2 : 0.08)
            : (isDark ? const Color(0xFF282D3F) : const Color(0xFFF7F9FC)),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isEbike ? primaryColor : Colors.transparent,
          width: isEbike ? 1.5 : 0,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isEbike ? primaryColor : Colors.grey.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isEbike ? Icons.pedal_bike_rounded : Icons.bluetooth_rounded,
            color: isEbike ? Colors.white : Colors.grey,
            size: 22,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                displayName,
                style: TextStyle(
                  fontWeight: isEbike ? FontWeight.bold : FontWeight.w500,
                  fontSize: 15,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isEbike)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: primaryColor,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  "PAIRED E-BIKE",
                  style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
        subtitle: Text(
          "${dev.remoteId.str} • Paired with Phone",
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
        trailing: isConnectingThis
            ? SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: primaryColor),
              )
            : ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                onPressed: () => _connectToDevice(dev),
                child: const Text(
                  "Connect",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
      ),
    );
  }

  Widget _buildScanResultTile(ScanResult result, bool isDark, Color primaryColor) {
    final dev = result.device;
    final isEbike = _isEbikeDevice(result);
    final displayName = dev.platformName.isNotEmpty
        ? dev.platformName
        : (result.advertisementData.advName.isNotEmpty
            ? result.advertisementData.advName
            : (isEbike ? 'Volt E-Bike Dashboard' : 'Unknown Peripheral'));
    final isConnectingThis = _connectingDeviceId == dev.remoteId.str;

    return Container(
      decoration: BoxDecoration(
        color: isEbike
            ? primaryColor.withValues(alpha: isDark ? 0.2 : 0.08)
            : (isDark ? const Color(0xFF282D3F) : const Color(0xFFF7F9FC)),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isEbike ? primaryColor : Colors.transparent,
          width: isEbike ? 1.5 : 0,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isEbike ? primaryColor : Colors.grey.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isEbike ? Icons.pedal_bike_rounded : Icons.bluetooth_rounded,
            color: isEbike ? Colors.white : Colors.grey,
            size: 22,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                displayName,
                style: TextStyle(
                  fontWeight: isEbike ? FontWeight.bold : FontWeight.w500,
                  fontSize: 15,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isEbike)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: primaryColor,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  "E-BIKE HOST",
                  style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
        subtitle: Text(
          "${dev.remoteId.str} • RSSI: ${result.rssi} dBm",
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
        trailing: isConnectingThis
            ? SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: primaryColor),
              )
            : ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isEbike ? primaryColor : (isDark ? Colors.white24 : Colors.grey[200]),
                  foregroundColor: isEbike ? Colors.white : (isDark ? Colors.white : Colors.black87),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                onPressed: () => _connectToDevice(dev),
                child: Text(
                  isEbike ? "Connect" : "Pair",
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
      ),
    );
  }
}
