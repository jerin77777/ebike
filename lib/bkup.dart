import 'dart:async';
import 'dart:io';

import 'package:rpi_gpio/gpio.dart';
import 'package:rpi_gpio/rpi_gpio.dart';

StreamController<double> speedController = StreamController<double>.broadcast();

/// Simple Raspberry Pi speedometer using a reed switch on BCM17 (physical pin 11).
/// - Uses internal pull-up (so reed should connect the pin to GND when closed).
/// - Debounces pulses (minMs). Prints MPH every second.
Future<void> listen() async {
  // --- Configuration ---
  const int physicalPin = 11; // physical header pin for BCM17
  const double radiusInches =
      13.5; // tire radius in inches (same as Arduino sketch)
  const int minMs =
      100; // ignore pulses faster than this (debounce / implausible)
  const int timeoutMs = 2000; // if no pulse within this -> speed = 0
  const Duration printInterval = Duration(seconds: 1);
  // ----------------------

  final double circumferenceInches = 2.0 * 3.141592653589793 * radiusInches;
  const double inchesPerMile = 5280.0 * 12.0; // 63360

  // initialize native gpio implementation for Raspberry Pi
  final gpio = await initialize_RpiGpio(); // returns an implementation of Gpio
  // optional: change polling frequency for input streams (default ~10ms)
  gpio.pollingFrequency = Duration(milliseconds: 5);

  // open pin as input with internal pull-up (Pull.up)
  final input = gpio.input(physicalPin, Pull.up);

  bool? lastRawValue; // null until first sampled value
  int? lastAcceptedMs; // epoch millis of last accepted (debounced) pulse
  int? lastIntervalMs; // ms between last two accepted pulses
  int lastSeenMs = DateTime.now().millisecondsSinceEpoch;

  // listen for value changes (GpioInput.values stream)
  final sub = input.values.listen((bool rawValue) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // With pull-up: idle = HIGH (true). Reed CLOSED => pin pulled to GND => LOW (false).
    // We want to trigger on the falling edge: true -> false.
    if (lastRawValue == true && rawValue == false) {
      // candidate pulse
      if (lastAcceptedMs == null) {
        // first pulse: accept but we don't have an interval yet
        lastAcceptedMs = nowMs;
      } else {
        final dt = nowMs - lastAcceptedMs!;
        if (dt >= minMs) {
          lastIntervalMs = dt;
          lastAcceptedMs = nowMs;
        } // else: ignore as bounce / too fast
      }
      lastSeenMs = nowMs;
    } else if (rawValue == true) {
      // when line goes back to HIGH we still update lastSeen
      lastSeenMs = nowMs;
    }

    lastRawValue = rawValue;
  });

  // periodic printer
  final timer = Timer.periodic(printInterval, (_) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    double mph = 0.0;
    if (lastIntervalMs != null && (nowMs - lastSeenMs) <= timeoutMs) {
      // mph = circumference_in_inches * 3600000 / (inches_per_mile * ms_per_rotation)
      mph =
          (circumferenceInches * 3600000.0) / (inchesPerMile * lastIntervalMs!);
    } else {
      mph = 0.0;
    }

    // print a single numeric value (matching Arduino Serial.println style)
    // one decimal place
    speedController?.add(mph);
    // print(mph.toStringAsFixed(1));
  });

  // cleanup on exit
  void cleanExit([int exitCode = 0]) async {
    timer.cancel();
    await sub.cancel();
    await gpio.dispose();
    exit(exitCode);
  }

  // SIGINT / SIGTERM handling
  ProcessSignal.sigint.watch().listen((_) => cleanExit(0));
  ProcessSignal.sigterm.watch().listen((_) => cleanExit(0));

  // keep program alive
  // (the listeners + timer keep it alive; this just prevents falling off main)
  await Completer<void>().future;
}
