import 'dart:async';
import 'dart:io';

import 'package:rpi_gpio/gpio.dart';
import 'package:rpi_gpio/rpi_gpio.dart';

StreamController<double> speedController = StreamController<double>.broadcast();

// Controllers for additional states
StreamController<String> indicatorController =
    StreamController<String>.broadcast(); // "none", "left", "right"
StreamController<String> lightController =
    StreamController<String>.broadcast(); // "low_beam", "high_beam"
StreamController<int> speedModeController =
    StreamController<int>.broadcast(); // 1, 2, 3
StreamController<bool> reverseController =
    StreamController<bool>.broadcast(); // true / false

/// Simple Raspberry Pi 4B speedometer & switch listener using rpi_gpio.
/// Pin mapping matches the custom hardware wiring diagram (40-Pin Header physical pins):
/// - Pin 32 (BCM GPIO 12): Speedometer Hall Sensor Pulse (EM100 Controller Output)
/// - Pin 35 (BCM GPIO 19): Controller Mode Line 1
/// - Pin 37 (BCM GPIO 26): Controller Mode Line 2
/// - Pin 36 (BCM GPIO 16): Turn Indicator Left
/// - Pin 40 (BCM GPIO 21): Turn Indicator Right
/// - Pin 23 (BCM GPIO 11): Low Beam Headlight Switch
/// - Pin 24 (BCM GPIO 8):  High Beam Headlight Switch
/// - Pin 22 (BCM GPIO 25): Reverse Mode Switch
///
/// NOTE on Ground:
/// Physical Pin 30 and Pin 34 are Ground pins directly adjacent to Pin 32.
/// Connect EM100 Ground and the voltage divider / level shifter Ground here.
Future<void> listen() async {
  // --- Configuration (Raspberry Pi 40-Pin Header Physical Pin Numbers) ---
  const int hallSpeedometerPin = 32; // Speedometer Hall Sensor Pulse (BCM GPIO 12)
  const int speedMode1Pin = 35;      // Controller Mode Line 1 (BCM GPIO 19)
  const int speedMode2Pin = 37;      // Controller Mode Line 2 (BCM GPIO 26)
  const int indicatorLeftPin = 36;   // Turn Indicator Left (BCM GPIO 16)
  const int indicatorRightPin = 40;  // Turn Indicator Right (BCM GPIO 21)
  const int lowBeamPin = 23;         // Low Beam Switch (BCM GPIO 11)
  const int highBeamPin = 24;        // High Beam Switch (BCM GPIO 8)
  const int reversePin = 22;         // Reverse Switch (BCM GPIO 25)

  // --- Speedometer Calibration & Timing ---
  // Formula: speed_kmh = frequency_hz * calibrationFactor
  //
  // CALIBRATION GUIDE:
  // 1. Put the ebike on a stand with the driven wheel free.
  // 2. Run this program and observe the logged Hall pulse frequency (Hz) at steady throttle.
  // 3. Compare with a reference (e.g. GPS speedometer on test run or rolling road).
  //    calibrationFactor = GPS_speed_kmh / Measured_Hz
  //    Example: 20 km/h at 50 Hz  => 20 / 50 = 0.40
  //             50 km/h at 100 Hz => 50 / 100 = 0.50
  const double calibrationFactor = 0.4; // km/h per Hz (tune for your motor/controller)

  const Duration sampleInterval = Duration(milliseconds: 250); // Speed update every 250ms (4 Hz)
  const int timeoutMs = 1200; // If no pulse within 1.2s -> speed drops to 0.0 km/h
  const int minPulseIntervalMs = 1; // 1ms glitch filter (supports up to ~1000 Hz pulse rates)

  // monotonic stopwatch for timing (reliable vs. system clock changes)
  final sw = Stopwatch()..start();

  // initialize native gpio implementation for Raspberry Pi
  final gpio = await initialize_RpiGpio(); // returns an implementation of Gpio
  // 1ms polling frequency allows capturing up to ~500 Hz pulse signals accurately
  gpio.pollingFrequency = const Duration(milliseconds: 1);

  // --- Hall Speedometer input ---
  // Pin 32 (BCM 12). Pull.off because external voltage divider / level shifter sets logic levels.
  // If your level shifter / optocoupler requires internal pull-down or pull-up, adjust accordingly.
  final hallInput = gpio.input(hallSpeedometerPin, Pull.off);

  bool? lastHallRaw;
  int pulseCountInWindow = 0;
  int lastPulseMs = 0;
  int lastSampleWindowMs = sw.elapsedMilliseconds;
  int lastLogMs = 0;
  double currentSpeedKmh = 0.0;

  final hallSub = hallInput.values.listen((bool rawValue) {
    final nowMs = sw.elapsedMilliseconds;

    // Detect RISING EDGE: LOW (false) -> HIGH (true)
    if (lastHallRaw == false && rawValue == true) {
      if (lastPulseMs == 0 || (nowMs - lastPulseMs) >= minPulseIntervalMs) {
        pulseCountInWindow++;
        lastPulseMs = nowMs;
      }
    }
    lastHallRaw = rawValue;
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

  // Periodic speed calculator & publisher (runs every 250ms for smooth UI response)
  final speedTimer = Timer.periodic(sampleInterval, (_) {
    final nowMs = sw.elapsedMilliseconds;
    final int dtMs = nowMs - lastSampleWindowMs;
    lastSampleWindowMs = nowMs;

    final int pulses = pulseCountInWindow;
    pulseCountInWindow = 0;

    double frequencyHz = 0.0;

    if (lastPulseMs > 0 && (nowMs - lastPulseMs) <= timeoutMs && dtMs > 0) {
      frequencyHz = (pulses * 1000.0) / dtMs;
      final double targetSpeedKmh = frequencyHz * calibrationFactor;
      // Slight smoothing filter for stable display readings
      if (pulses > 0) {
        currentSpeedKmh = (currentSpeedKmh * 0.3) + (targetSpeedKmh * 0.7);
      } else {
        // Decay speed if no pulses arrived in this particular sub-window
        currentSpeedKmh *= 0.5;
        if (currentSpeedKmh < 0.2) currentSpeedKmh = 0.0;
      }
    } else {
      frequencyHz = 0.0;
      currentSpeedKmh = 0.0;
    }

    // Publish speed in km/h to dashboard and telemetry
    final double displaySpeed = double.parse(currentSpeedKmh.toStringAsFixed(1));
    speedController.add(displaySpeed);

    // Diagnostic logging once per second while active (helps calibration)
    if ((nowMs - lastLogMs) >= 1000) {
      lastLogMs = nowMs;
      if (displaySpeed > 0 || pulses > 0) {
        stdout.writeln(
          '[Speedometer] Pulses/sec (Hz): ${frequencyHz.toStringAsFixed(1)} | '
          'Speed: ${displaySpeed.toStringAsFixed(1)} km/h',
        );
      }
    }
  });

  // cleanup on exit
  void cleanExit([int exitCode = 0]) async {
    speedTimer.cancel();
    await hallSub.cancel();
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
