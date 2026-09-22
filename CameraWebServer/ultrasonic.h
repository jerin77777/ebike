// ultrasonic.h — HC-SR04 driver for ESP32-CAM (AI_THINKER)
// Pins: TRIG = GPIO 12, ECHO = GPIO 13
// These are free on AI_THINKER; no camera pins are touched.
//
// Usage:
//   #include "ultrasonic.h"
//   ultrasonicSetup();            // call once in setup()
//   float d = ultrasonicReadCm(); // call in loop(); returns -1 on timeout
//   bool  t = ultrasonicTriggered(ULTRASONIC_THRESHOLD_CM); // true when object is closer than threshold

#ifndef ULTRASONIC_H
#define ULTRASONIC_H

#include <Arduino.h>

// ---- Pin & timing config ----
#define ULTRASONIC_TRIG_PIN     13      // GPIO 13 — free on AI_THINKER
#define ULTRASONIC_ECHO_PIN     14      // GPIO 14 — free on AI_THINKER
#define ULTRASONIC_THRESHOLD_CM 50.0f   // stream when object is closer than this
#define ULTRASONIC_TIMEOUT_US   25000UL // ~4.25 m max range (safe timeout)
#define ULTRASONIC_MIN_INTERVAL_MS 30   // minimum ms between reads (HC-SR04 needs ~20 ms)

// ---- Internal state ----
static unsigned long _us_lastRead = 0;
static float         _us_lastDist = -1.0f;

// Call once from setup()
inline void ultrasonicSetup() {
  pinMode(ULTRASONIC_TRIG_PIN, OUTPUT);
  pinMode(ULTRASONIC_ECHO_PIN, INPUT);
  digitalWrite(ULTRASONIC_TRIG_PIN, LOW);
  Serial.printf("[Ultrasonic] TRIG=GPIO%d  ECHO=GPIO%d  threshold=%.0f cm\n",
                ULTRASONIC_TRIG_PIN, ULTRASONIC_ECHO_PIN, ULTRASONIC_THRESHOLD_CM);
}

// Returns distance in cm, or -1.0 on timeout.
// Skips measurement if called faster than ULTRASONIC_MIN_INTERVAL_MS.
inline float ultrasonicReadCm() {
  unsigned long now = millis();
  if (now - _us_lastRead < ULTRASONIC_MIN_INTERVAL_MS) {
    return _us_lastDist; // return cached value
  }
  _us_lastRead = now;

  // Trigger pulse: 10 us HIGH
  digitalWrite(ULTRASONIC_TRIG_PIN, LOW);
  delayMicroseconds(2);
  digitalWrite(ULTRASONIC_TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(ULTRASONIC_TRIG_PIN, LOW);

  // Measure echo pulse width (timeout = ULTRASONIC_TIMEOUT_US)
  unsigned long duration = pulseIn(ULTRASONIC_ECHO_PIN, HIGH, ULTRASONIC_TIMEOUT_US);
  if (duration == 0) {
    _us_lastDist = -1.0f; // timeout / no object
    return _us_lastDist;
  }

  // Distance = (time * speed of sound) / 2
  // speed of sound ~= 0.0343 cm/us
  _us_lastDist = (duration * 0.0343f) / 2.0f;
  return _us_lastDist;
}

// Returns true when an object is detected CLOSER than thresholdCm.
// Ignores timeout readings (-1) so stale/no-echo never falsely triggers.
inline bool ultrasonicTriggered(float thresholdCm = ULTRASONIC_THRESHOLD_CM) {
  float d = ultrasonicReadCm();
  return (d > 0.0f && d < thresholdCm);
}

#endif // ULTRASONIC_H
