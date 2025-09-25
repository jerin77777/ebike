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
  const int speedMode1Pin = 12;
  const int speedMode2Pin = 13;
  const int lowBeamPin = 15;
  const int highBeamPin = 16;
  const int indicatorLeftPin = 18;
  const int indicatorRightPin = 22;
  const int reversePin = 32;

  const double radiusInches = 18;
  const int timeoutMs = 2000; // keep this or lower if you want faster zeroing
  final Duration printInterval = Duration(milliseconds: 250); // faster updates

  const int pulsesPerRotation = 2;

  // debounce window (ms) -- reduce to lower latency but watch for bounces
  const int debounceMs = 25;
  // ----------------------

  final double circumferenceInches = 2.0 * 3.141592653589793 * radiusInches;
  const double inchesPerMile = 5280.0 * 12.0; // 63360

  final sw = Stopwatch()..start();

  final gpio = await initialize_RpiGpio();
  // faster polling for lower latency (be careful with CPU usage)
  gpio.pollingFrequency = Duration(milliseconds: 2);

  final reedInput = gpio.input(reedPhysicalPin, Pull.up);

  bool? lastRawValue;
  int? lastAcceptedPulseUs; // microseconds of last accepted pulse
  int? lastIntervalUs; // microseconds between accepted pulses (adjacent)
  int lastSeenUs = sw.elapsedMicroseconds;

  final reedSub = reedInput.values.listen((bool rawValue) {
    final nowUs = sw.elapsedMicroseconds;

    if (lastRawValue == true && rawValue == false) {
      // falling edge candidate
      if (lastAcceptedPulseUs == null) {
        lastAcceptedPulseUs = nowUs;
      } else {
        final dtUs = nowUs - lastAcceptedPulseUs!;
        final debounceUs = debounceMs * 1000;
        if (dtUs >= debounceUs) {
          lastIntervalUs = dtUs;
          lastAcceptedPulseUs = nowUs;

          // immediate speed computation & publish on accepted pulse:
          final double msPerRotation =
              (lastIntervalUs! * pulsesPerRotation) / 1000.0;
          final double mph = (circumferenceInches * 3600000.0) /
              (inchesPerMile * msPerRotation);
          speedController.add(mph);
        }
      }
      lastSeenUs = nowUs;
    } else if (rawValue == true) {
      lastSeenUs = nowUs;
    }

    lastRawValue = rawValue;
  });

  // --- other inputs (unchanged) ---
  final speed1Input = gpio.input(speedMode1Pin, Pull.up);
  final speed2Input = gpio.input(speedMode2Pin, Pull.up);
  final lowBeamInput = gpio.input(lowBeamPin, Pull.up);
  final highBeamInput = gpio.input(highBeamPin, Pull.up);
  final indLeftInput = gpio.input(indicatorLeftPin, Pull.up);
  final indRightInput = gpio.input(indicatorRightPin, Pull.up);
  final reverseInput = gpio.input(reversePin, Pull.up);

  bool lastSpeed1Raw = true;
  bool lastSpeed2Raw = true;
  bool lastLowRaw = true;
  bool lastHighRaw = true;
  bool lastIndLeftRaw = true;
  bool lastIndRightRaw = true;
  bool lastReverseRaw = true;

  String lastIndicatorState = "none";
  String lastLightState = "low_beam";
  int lastSpeedMode = 3;
  bool lastReverseState = false;

  void recomputeAndEmit() {
    final bool speed1Pressed = lastSpeed1Raw == false;
    final bool speed2Pressed = lastSpeed2Raw == false;
    final bool lowPressed = lastLowRaw == false;
    final bool highPressed = lastHighRaw == false;
    final bool indLeftPressed = lastIndLeftRaw == false;
    final bool indRightPressed = lastIndRightRaw == false;
    final bool reversePressed = lastReverseRaw == false;

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

    String lightState;
    if (highPressed) {
      lightState = "high_beam";
    } else {
      lightState = "low_beam";
    }
    if (lightState != lastLightState) {
      lastLightState = lightState;
      lightController.add(lightState);
    }

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

    if (reversePressed != lastReverseState) {
      lastReverseState = reversePressed;
      reverseController.add(reversePressed);
    }
  }

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

  final timer = Timer.periodic(printInterval, (_) {
    final nowUs = sw.elapsedMicroseconds;

    double mph = 0.0;
    // use microsecond-based 'lastSeenUs' for timeout check
    if (lastIntervalUs != null &&
        (nowUs - lastSeenUs) <= (timeoutMs * 1000)) {
      final msPerRotation = (lastIntervalUs! * pulsesPerRotation) / 1000.0;
      mph = (circumferenceInches * 3600000.0) / (inchesPerMile * msPerRotation);
    } else {
      mph = 0.0;
    }

    // periodic publish (keeps UI updated and emits zeros after timeout)
    speedController.add(mph);
  });

  void cleanExit([int exitCode = 0]) async {
    timer.cancel();
    await reedSub.cancel();
    for (final s in subs) {
      await s.cancel();
    }
    await gpio.dispose();

    await indicatorController.close();
    await lightController.close();
    await speedModeController.close();
    await reverseController.close();
    await speedController.close();

    exit(exitCode);
  }

  ProcessSignal.sigint.watch().listen((_) => cleanExit(0));
  ProcessSignal.sigterm.watch().listen((_) => cleanExit(0));

  await Completer<void>().future;
}

