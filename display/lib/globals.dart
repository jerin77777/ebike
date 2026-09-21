import 'dart:async';
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