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

/// Simple Radxa Zero 3W speedometer using a Hall sensor on Physical Pin 32 (GPIOAO_4 / Linux GPIO 416).
/// - Uses internal pull-up (so Hall sensor / reed connects pin to GND when triggered).
/// - Debounces pulses (minMs). Prints MPH every second.
Future<void> listen() async {
  // --- Configuration (Radxa Zero 3W 40-Pin Header Numbering) ---
  const int reedPhysicalPin = 32;    // Speedometer Hall Sensor (GPIOAO_4 / Linux GPIO 416)
  const int speedMode1Pin = 35;      // Controller Mode Line 1 (GPIOAO_8 / Linux GPIO 420)
  const int speedMode2Pin = 37;      // Controller Mode Line 2 (GPIOAO_9 / Linux GPIO 421)
  const int indicatorLeftPin = 36;   // Turn Indicator Left (GPIOH_8 / Linux GPIO 451)
  const int indicatorRightPin = 40;  // Turn Indicator Right (GPIOAO_11 / Linux GPIO 423)
  const int lowBeamPin = 23;         // Low Beam Switch (GPIOH_7 / Linux GPIO 450)
  const int highBeamPin = 24;        // High Beam Switch (GPIOH_6 / Linux GPIO 449)
  const int reversePin = 22;         // Reverse Switch (GPIOC_7 / Linux GPIO 475)

  const double radiusInches = 18; // tire radius in inches (same as Arduino sketch)
  const int timeoutMs = 2000; // if no pulse within this -> speed = 0
  const Duration printInterval = Duration(seconds: 1);

  // For two magnets on the wheel:
  const int pulsesPerRotation = 2;

  // debounce: ignore multiple falling edges inside this window (ms).
  // tune this for your hardware; 30-50ms works for most reed switches.
  const int debounceMs = 40;
  // ----------------------

  final double circumferenceInches = 2.0 * 3.141592653589793 * radiusInches;
  const double inchesPerMile = 5280.0 * 12.0; // 63360

  // monotonic stopwatch for timing (reliable vs. system clock changes)
  final sw = Stopwatch()..start();

  // initialize native gpio implementation for Raspberry Pi
  final gpio = await initialize_RpiGpio(); // returns an implementation of Gpio
  // optional: change polling frequency for input streams (default ~10ms)
  gpio.pollingFrequency = Duration(milliseconds: 5);

  // --- Reed input ---
  final reedInput = gpio.input(reedPhysicalPin, Pull.up);

  bool? lastRawValue; // null until first sampled value
  int? lastAcceptedPulseMs; // monotonic ms of last accepted pulse
  int? lastIntervalMs; // ms between last two accepted pulses (time between pulses)
  int lastSeenMs = sw.elapsedMilliseconds;

  final reedSub = reedInput.values.listen((bool rawValue) {
    final nowMs = sw.elapsedMilliseconds;

    // With pull-up: idle = HIGH (true). Reed CLOSED => pin pulled to GND => LOW (false).
    // Trigger on falling edge: true -> false.
    if (lastRawValue == true && rawValue == false) {
      // candidate pulse (falling edge)
      if (lastAcceptedPulseMs == null) {
        // first accepted pulse
        lastAcceptedPulseMs = nowMs;
      } else {
        final dt = nowMs - lastAcceptedPulseMs!;
        // accept only if outside debounce window
        if (dt >= debounceMs) {
          lastIntervalMs = dt;
          lastAcceptedPulseMs = nowMs;
        } // else: ignore as bounce / duplicate
      }
      lastSeenMs = nowMs;
    } else if (rawValue == true) {
      // when line goes back to HIGH we still update lastSeen
      lastSeenMs = nowMs;
    }

    lastRawValue = rawValue;
  });

  // --- Additional switch inputs (unchanged) ---
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

  // periodic printer for speed — keep it as your single numeric stream publisher
  final timer = Timer.periodic(printInterval, (_) {
    final nowMs = sw.elapsedMilliseconds;

    double mph = 0.0;
    if (lastIntervalMs != null && (nowMs - lastSeenMs) <= timeoutMs) {
      // lastIntervalMs = ms between adjacent pulses
      final msPerRotation = lastIntervalMs! * pulsesPerRotation;
      // mph = circumference_in_inches * 3600000 / (inches_per_mile * ms_per_rotation)
      mph = (circumferenceInches * 3600000.0) / (inchesPerMile * msPerRotation);
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
