import 'dart:async';
import 'dart:io';

import 'package:rpi_gpio/gpio.dart';
import 'package:rpi_gpio/rpi_gpio.dart';

StreamController<double> speedController = StreamController<double>.broadcast();

// New controllers for additional states
StreamController<String> indicatorController =
    StreamController<String>.broadcast(); // "none", "left", "right"
StreamController<String> lightController =
    StreamController<String>.broadcast(); // "low_beam", "high_beam"
StreamController<int> speedModeController =
    StreamController<int>.broadcast(); // 1, 2, 3
StreamController<bool> reverseController =
    StreamController<bool>.broadcast(); // true / false

/// Simple Raspberry Pi speedometer using a reed switch on BCM17 (physical pin 11).
/// - Uses internal pull-up (so reed should connect the pin to GND when closed).
/// - Debounces pulses (minMs). Prints MPH every second.
///
/// Reed switch logic is **left intact** from your original code.
Future<void> listen() async {
  // --- Configuration ---
  const int reedPhysicalPin = 11; // physical header pin for BCM17 (your reed)
  // Additional switch pins (physical header numbering) — matches prior suggestion:
  const int speedMode1Pin = 12; // physical pin -> BCM18
  const int speedMode2Pin = 13; // physical pin -> BCM27
  const int lowBeamPin = 15; // physical pin -> BCM22
  const int highBeamPin = 16; // physical pin -> BCM23
  const int indicatorLeftPin = 18; // physical pin -> BCM24
  const int indicatorRightPin = 22; // physical pin -> BCM25
  const int reversePin = 32; // physical pin -> BCM12

  const double radiusInches = 13.5; // tire radius in inches (same as Arduino sketch)
  const int minMs = 100; // ignore pulses faster than this (debounce / implausible)
  const int timeoutMs = 2000; // if no pulse within this -> speed = 0
  const Duration printInterval = Duration(seconds: 1);
  // ----------------------

  final double circumferenceInches =
      2.0 * 3.141592653589793 * radiusInches;
  const double inchesPerMile = 5280.0 * 12.0; // 63360

  // initialize native gpio implementation for Raspberry Pi
  final gpio = await initialize_RpiGpio(); // returns an implementation of Gpio
  // optional: change polling frequency for input streams (default ~10ms)
  gpio.pollingFrequency = Duration(milliseconds: 5);

  // --- Reed input (unchanged logic, using your original variable names where possible) ---
  final reedInput = gpio.input(reedPhysicalPin, Pull.up);

  bool? lastRawValue; // null until first sampled value
  int? lastAcceptedMs; // epoch millis of last accepted (debounced) pulse
  int? lastIntervalMs; // ms between last two accepted pulses
  int lastSeenMs = DateTime.now().millisecondsSinceEpoch;

  final reedSub = reedInput.values.listen((bool rawValue) {
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

  // --- Additional switch inputs ---
  final speed1Input = gpio.input(speedMode1Pin, Pull.up);
  final speed2Input = gpio.input(speedMode2Pin, Pull.up);
  final lowBeamInput = gpio.input(lowBeamPin, Pull.up);
  final highBeamInput = gpio.input(highBeamPin, Pull.up);
  final indLeftInput = gpio.input(indicatorLeftPin, Pull.up);
  final indRightInput = gpio.input(indicatorRightPin, Pull.up);
  final reverseInput = gpio.input(reversePin, Pull.up);

  // hold last known raw values (true = HIGH idle, false = pressed to GND)
  bool lastSpeed1Raw = true;
  bool lastSpeed2Raw = true;
  bool lastLowRaw = true;
  bool lastHighRaw = true;
  bool lastIndLeftRaw = true;
  bool lastIndRightRaw = true;
  bool lastReverseRaw = true;

  // hold last emitted derived states so we only push changes
  String lastIndicatorState = "none";
  String lastLightState = "low_beam";
  int lastSpeedMode = 3;
  bool lastReverseState = false;

  // helper: compute derived states and emit if changed
  void recomputeAndEmit() {
    // pressed = active-low => pressed when raw == false
    final bool speed1Pressed = lastSpeed1Raw == false;
    final bool speed2Pressed = lastSpeed2Raw == false;
    final bool lowPressed = lastLowRaw == false;
    final bool highPressed = lastHighRaw == false;
    final bool indLeftPressed = lastIndLeftRaw == false;
    final bool indRightPressed = lastIndRightRaw == false;
    final bool reversePressed = lastReverseRaw == false;

    // indicator: none / left / right
    String indicatorState;
    if (indLeftPressed && !indRightPressed) {
      indicatorState = "left";
    } else if (indRightPressed && !indLeftPressed) {
      indicatorState = "right";
    } else {
      // when neither or both are pressed we return "none" per your spec (adjustable)
      indicatorState = "none";
    }

    if (indicatorState != lastIndicatorState) {
      lastIndicatorState = indicatorState;
      indicatorController.add(indicatorState);
    }

    // light: high_beam / low_beam (default to low_beam when neither pressed)
    String lightState;
    if (highPressed) {
      lightState = "high_beam";
    } else if (lowPressed) {
      lightState = "low_beam";
    } else {
      // default to low_beam when neither pressed (common in vehicle behavior).
      lightState = "low_beam";
    }

    if (lightState != lastLightState) {
      lastLightState = lightState;
      lightController.add(lightState);
    }

    // speed mode: 1, 2, otherwise 3
    int speedMode;
    if (speed1Pressed) {
      speedMode = 1;
    } else if (speed2Pressed) {
      speedMode = 2;
    } else {
      speedMode = 3;
    }

    if (speedMode != lastSpeedMode) {
      lastSpeedMode = speedMode;
      speedModeController.add(speedMode);
    }

    // reverse: emit true/false on change
    if (reversePressed != lastReverseState) {
      lastReverseState = reversePressed;
      reverseController.add(reversePressed);
    }
  }

  // subscribe to each input .values stream and update lastRaw values, then recompute
  final subs = <StreamSubscription<bool>>[
    speed1Input.values.listen((v) {
      lastSpeed1Raw = v;
      recomputeAndEmit();
    }),
    speed2Input.values.listen((v) {
      lastSpeed2Raw = v;
      recomputeAndEmit();
    }),
    lowBeamInput.values.listen((v) {
      lastLowRaw = v;
      recomputeAndEmit();
    }),
    highBeamInput.values.listen((v) {
      lastHighRaw = v;
      recomputeAndEmit();
    }),
    indLeftInput.values.listen((v) {
      lastIndLeftRaw = v;
      recomputeAndEmit();
    }),
    indRightInput.values.listen((v) {
      lastIndRightRaw = v;
      recomputeAndEmit();
    }),
    reverseInput.values.listen((v) {
      lastReverseRaw = v;
      recomputeAndEmit();
    }),
  ];

  // periodic printer for speed (unchanged logic), but keep it as your single numeric stream publisher
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

    // publish speed (matching your Arduino Serial.println single-value style)
    speedController.add(mph);
  });

  // cleanup on exit
  void cleanExit([int exitCode = 0]) async {
    timer.cancel();
    await reedSub.cancel();
    for (final s in subs) {
      await s.cancel();
    }

    // dispose gpio and close controllers
    await gpio.dispose();

    // close controllers (if you want them to be closed on exit)
    await indicatorController.close();
    await lightController.close();
    await speedModeController.close();
    await reverseController.close();
    await speedController.close();

    exit(exitCode);
  }

  // SIGINT / SIGTERM handling
  ProcessSignal.sigint.watch().listen((_) => cleanExit(0));
  ProcessSignal.sigterm.watch().listen((_) => cleanExit(0));

  // keep program alive
  await Completer<void>().future;
}
