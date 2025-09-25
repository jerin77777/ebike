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
  const int timeoutMs = 2000; // time to zero when no pulses
  final Duration publishInterval = Duration(milliseconds: 200); // periodic fallback

  const int pulsesPerRotation = 2;

  // debounce (ms) -- keep reasonably high to avoid bounces being accepted.
  const int debounceMs = 30;
  // interval buffer & outlier settings
  const int intervalBufferSize = 5; // small buffer of recent adjacent-pulse intervals
  const double outlierLowerFactor = 0.5; // lower bound relative to median
  const double outlierUpperFactor = 2.5; // upper bound relative to median
  const double maxSpeedMph = 120.0; // clamp impossible speeds above this
  const double emaAlpha = 0.35; // smoothing for published MPH (0..1) - higher = less smoothing
  // ----------------------

  final double circumferenceInches = 2.0 * 3.141592653589793 * radiusInches;
  const double inchesPerMile = 5280.0 * 12.0; // 63360

  // compute a minimum plausible interval (microseconds) for the configured maxSpeed
  // lastIntervalUs corresponds to time between adjacent pulses (not full rotation)
  final double minIntervalUsForMaxSpeed = ((circumferenceInches * 3600000.0) /
          (inchesPerMile * maxSpeedMph)) *
      1000.0 /
      pulsesPerRotation;

  final sw = Stopwatch()..start();

  final gpio = await initialize_RpiGpio();
  gpio.pollingFrequency = Duration(milliseconds: 3);

  final reedInput = gpio.input(reedPhysicalPin, Pull.up);

  bool? lastRawValue;
  int? lastAcceptedPulseUs; // microseconds
  int lastSeenUs = sw.elapsedMicroseconds;

  // small circular buffer of recent adjacent-pulse intervals (microseconds)
  final List<int> intervalBuf = <int>[];
  double emaMph = 0.0; // EMA for published mph (starts at 0)

  // helper: compute median of list<int>
  int _median(List<int> xs) {
    if (xs.isEmpty) return 0;
    final copy = List<int>.from(xs)..sort();
    final mid = copy.length ~/ 2;
    if (copy.length.isOdd) return copy[mid];
    return ((copy[mid - 1] + copy[mid]) ~/ 2);
  }

  // compute average (double) of intervalBuf
  double _avgIntervalUs() {
    if (intervalBuf.isEmpty) return 0.0;
    final sum = intervalBuf.fold<int>(0, (p, e) => p + e);
    return sum / intervalBuf.length;
  }

  // calculate mph from an average interval (microseconds between adjacent pulses)
  double _mphFromAvgIntervalUs(double avgIntervalUs) {
    if (avgIntervalUs <= 0.0) return 0.0;
    final msPerRotation = (avgIntervalUs * pulsesPerRotation) / 1000.0;
    if (msPerRotation <= 0.0) return 0.0;
    return (circumferenceInches * 3600000.0) / (inchesPerMile * msPerRotation);
  }

  // Publish a new mph value (applies EMA smoothing)
  void _publishMphImmediate(double rawMph) {
    // clamp to [0, maxSpeedMph*1.2] for safety (allow a little headroom)
    final double clamped = rawMph.clamp(0.0, maxSpeedMph * 1.2);
    // initialize EMA to first measurement if currently zero
    if (emaMph == 0.0) {
      emaMph = clamped;
    } else {
      emaMph = emaAlpha * clamped + (1.0 - emaAlpha) * emaMph;
    }
    speedController.add(emaMph);
  }

  final reedSub = reedInput.values.listen((bool rawValue) {
    final nowUs = sw.elapsedMicroseconds;

    // falling edge detection (idle HIGH, closed -> LOW)
    if (lastRawValue == true && rawValue == false) {
      if (lastAcceptedPulseUs == null) {
        // first accepted pulse (can't form an interval yet)
        lastAcceptedPulseUs = nowUs;
      } else {
        final dtUs = nowUs - lastAcceptedPulseUs!;
        final debounceUs = debounceMs * 1000;

        // ignore very close edges (debounce)
        if (dtUs >= debounceUs) {
          // reject impossible-too-short intervals (likely bounce / glitch)
          if (dtUs < minIntervalUsForMaxSpeed) {
            // ignore this dt as impossible given maxSpeed; do NOT update lastAcceptedPulseUs
            // (do not push to buffer) — this prevents tiny dt spikes
          } else {
            // outlier filtering relative to current buffer median (if we have history)
            if (intervalBuf.isNotEmpty) {
              final med = _median(intervalBuf);
              final lower = (med * outlierLowerFactor).toInt();
              final upper = (med * outlierUpperFactor).toInt();

              if (dtUs < lower || dtUs > upper) {
                // treat as outlier: push median instead of the extreme dt to keep the buffer stable
                intervalBuf.add(med);
              } else {
                // normal: push new dt
                intervalBuf.add(dtUs);
              }
            } else {
              // buffer empty: accept first dt
              intervalBuf.add(dtUs);
            }

            // keep buffer size bounded
            if (intervalBuf.length > intervalBufferSize) {
              intervalBuf.removeAt(0);
            }

            lastAcceptedPulseUs = nowUs;

            // compute speed from buffered average and publish immediately (low latency)
            final avgUs = _avgIntervalUs();
            final mph = _mphFromAvgIntervalUs(avgUs);
            _publishMphImmediate(mph);
          }
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

  // periodic publisher to emit zero on timeout and keep UI updated if no pulses
  final timer = Timer.periodic(publishInterval, (_) {
    final nowUs = sw.elapsedMicroseconds;

    // timeout -> zero
    if ((nowUs - lastSeenUs) > (timeoutMs * 1000)) {
      // clear buffer so next pulses start fresh
      intervalBuf.clear();
      emaMph = 0.0;
      speedController.add(0.0);
      return;
    }

    // if we have buffered intervals, periodically republish smoothed speed to keep UI alive
    if (intervalBuf.isNotEmpty) {
      final avgUs = _avgIntervalUs();
      final mph = _mphFromAvgIntervalUs(avgUs);
      _publishMphImmediate(mph);
    }
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


