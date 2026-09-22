// ==============================================================================
// ESP32-CAM: Ultrasonic Proximity (<50cm) Streaming & Raspberry Pi Hotspot Client
// ==============================================================================
// - Measures distance using HC-SR04 ultrasonic sensor (TRIG: 13, ECHO: 14)
// - Connects to Raspberry Pi Hotspot ("EBike-ESP32-AP", default pass: "ebike1234")
// - Automatically streams camera frames to WebSocket server (ws://10.42.0.1:5001/ws)
//   whenever the range is below 50 cm or reverse mode is triggered.
// - Auto-reconnects when Raspberry Pi hotspot is turned ON (via 'h' key on Pi)
// - Also allows manual reconnect by sending 'h' via Serial Monitor.
// ==============================================================================

#include "esp_camera.h"
#include <WiFi.h>
#include <WiFiClient.h>
#include <ArduinoWebsockets.h>
#include "board_config.h" // Camera pin definitions (AI-Thinker / WROVER / etc.)

using namespace websockets;

// ------------------------------------------------------------------------------
// Ultrasonic Sensor Pin Definitions & Parameters
// ------------------------------------------------------------------------------
#define TRIG_PIN 13
#define ECHO_PIN 14

const float PROXIMITY_THRESHOLD_CM = 50.0; // Stream trigger threshold
const unsigned long PROXIMITY_HOLD_MS = 1500; // Keep streaming 1.5s after range clears

// ------------------------------------------------------------------------------
// Wi-Fi and Raspberry Pi WebSocket Server Configuration
// ------------------------------------------------------------------------------
// Raspberry Pi AP credentials (matches hotspot_config.env / toggle_hotspot.sh)
const char *rpi_ssid     = "ebike";
const char *rpi_password = "ebike1234";
const char *rpi_host     = "10.42.0.1";
const uint16_t rpi_ws_port = 5001;
const char *rpi_ws_path    = "/ws";

// Optional fallback Wi-Fi credentials for desk/home testing
const char *fallback_ssid     = "test";
const char *fallback_password = "";
const char *fallback_host     = "192.168.1.100";

// Active target configuration (defaults to Raspberry Pi Hotspot)
const char *active_ssid     = rpi_ssid;
const char *active_password = rpi_password;
const char *active_host     = rpi_host;

// Prototypes
void startCameraServer();
void setupLedFlash();
void connectWiFi(bool force = false);
void connectWebSocket();
void wsLoopOnce();
float measureDistanceCm();
bool sendImageBufferWs(const uint8_t *buf, size_t len);

// Global WebSocket client & state
WebsocketsClient wsClient;
volatile bool reverseStreamingEnabled = false;
unsigned long lastProximityTriggerMs = 0;
unsigned long lastSensorCheckMs = 0;
unsigned long lastWifiCheckMs = 0;
unsigned long lastWsCheckMs = 0;
float currentDistanceCm = -1.0;

// ------------------------------------------------------------------------------
// Setup
// ------------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  Serial.setDebugOutput(true);
  Serial.println();
  Serial.println("=========================================");
  Serial.println(" ESP32-CAM E-Bike Proximity & Stream Node");
  Serial.println("=========================================");

  // Initialize Ultrasonic Sensor Pins
  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);
  digitalWrite(TRIG_PIN, LOW);
  Serial.println("[OK] HC-SR04 Ultrasonic Sensor initialized (TRIG: 13, ECHO: 14)");

  // -------------------------
  // Camera Configuration
  // -------------------------
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0       = Y2_GPIO_NUM;
  config.pin_d1       = Y3_GPIO_NUM;
  config.pin_d2       = Y4_GPIO_NUM;
  config.pin_d3       = Y5_GPIO_NUM;
  config.pin_d4       = Y6_GPIO_NUM;
  config.pin_d5       = Y7_GPIO_NUM;
  config.pin_d6       = Y8_GPIO_NUM;
  config.pin_d7       = Y9_GPIO_NUM;
  config.pin_xclk     = XCLK_GPIO_NUM;
  config.pin_pclk     = PCLK_GPIO_NUM;
  config.pin_vsync    = VSYNC_GPIO_NUM;
  config.pin_href     = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn     = PWDN_GPIO_NUM;
  config.pin_reset    = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size   = FRAMESIZE_UXGA;
  config.grab_mode    = CAMERA_GRAB_WHEN_EMPTY;
  config.fb_location  = CAMERA_FB_IN_PSRAM;
  config.jpeg_quality = 12;
  config.fb_count     = 1;

  if (config.pixel_format == PIXFORMAT_JPEG) {
    if (psramFound()) {
      config.jpeg_quality = 10;
      config.fb_count     = 2;
      config.grab_mode    = CAMERA_GRAB_LATEST;
    } else {
      config.frame_size  = FRAMESIZE_SVGA;
      config.fb_location = CAMERA_FB_IN_DRAM;
    }
  } else {
    config.frame_size = FRAMESIZE_240X240;
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("[FAIL] Camera init failed with error 0x%x\n", err);
    while (true) delay(1000);
  }
  Serial.println("[OK] Camera initialized successfully.");

  sensor_t *s = esp_camera_sensor_get();
  if (s && s->id.PID == OV3660_PID) {
    s->set_vflip(s, 1);
    s->set_brightness(s, 1);
    s->set_saturation(s, -2);
  }
  if (s) {
    s->set_framesize(s, FRAMESIZE_QVGA); // Smooth streaming frame rate for display
  }

#if defined(LED_GPIO_NUM)
  setupLedFlash();
#endif

  // Optional: Start local HTTP camera server
  startCameraServer();

  // Connect to Wi-Fi
  connectWiFi(true);

  Serial.println("-----------------------------------------");
  Serial.println("System Ready!");
  Serial.printf("Proximity trigger: < %.1f cm\n", PROXIMITY_THRESHOLD_CM);
  Serial.println("Press 'h' in Serial Monitor anytime to force reconnect to Raspberry Pi AP.");
  Serial.println("-----------------------------------------");
}

// ------------------------------------------------------------------------------
// Measure Distance via HC-SR04
// ------------------------------------------------------------------------------
float measureDistanceCm() {
  digitalWrite(TRIG_PIN, LOW);
  delayMicroseconds(2);
  digitalWrite(TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);

  // 15000us timeout corresponds to ~250cm max detection.
  // Short timeout prevents loop blocking when no obstacle is present.
  long duration = pulseIn(ECHO_PIN, HIGH, 15000);

  if (duration == 0) {
    return -1.0; // Out of range or no echo
  }
  // Speed of sound: ~0.0343 cm/us -> (duration * 0.0343) / 2
  return (float)(duration * 0.0343) / 2.0;
}

// ------------------------------------------------------------------------------
// Wi-Fi Connection & Hotspot Handler
// ------------------------------------------------------------------------------
void connectWiFi(bool force) {
  if (!force && WiFi.status() == WL_CONNECTED) return;

  Serial.printf("\nConnecting to Wi-Fi AP [%s]...", active_ssid);
  WiFi.disconnect(true);
  delay(100);

  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  if (strlen(active_password) > 0) {
    WiFi.begin(active_ssid, active_password);
  } else {
    WiFi.begin(active_ssid);
  }

  unsigned long startAttempt = millis();
  // Wait up to 4 seconds per attempt
  while (WiFi.status() != WL_CONNECTED && millis() - startAttempt < 4000) {
    Serial.print(".");
    delay(250);
  }

  // If failed and password has < 8 chars (Linux AP creates open hotspot when < 8 chars), try open AP
  if (WiFi.status() != WL_CONNECTED && strlen(active_password) > 0 && strlen(active_password) < 8) {
    WiFi.disconnect();
    delay(50);
    WiFi.begin(active_ssid);
    startAttempt = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - startAttempt < 3000) {
      Serial.print(".");
      delay(250);
    }
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\n[✓] Wi-Fi Connected!");
    Serial.print("    Assigned IP: ");
    Serial.println(WiFi.localIP());
    connectWebSocket();
  } else {
    Serial.println("\n[!] Wi-Fi not connected yet (Raspberry Pi hotspot may be OFF).");
    Serial.println("    Press 'h' on Raspberry Pi to activate host AP.");
  }
}

// ------------------------------------------------------------------------------
// WebSocket Connection to Raspberry Pi
// ------------------------------------------------------------------------------
void connectWebSocket() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (wsClient.available()) return;

  String url = String("ws://") + active_host + ":" + String(rpi_ws_port) + rpi_ws_path;
  Serial.print("Connecting WebSocket to ");
  Serial.println(url);

  wsClient.onMessage([&](WebsocketsMessage message) {
    if (message.isText()) {
      String text = message.data();
      text.toLowerCase();
      text.trim();
      if (text == "start") {
        reverseStreamingEnabled = true;
        Serial.println("[WS Command] Stream START (Reverse Mode Active)");
      } else if (text == "stop") {
        reverseStreamingEnabled = false;
        Serial.println("[WS Command] Stream STOP (Reverse Mode Off)");
      }
    }
  });

  wsClient.onEvent([&](WebsocketsEvent event, String data) {
    if (event == WebsocketsEvent::ConnectionOpened) {
      Serial.println("[✓] WebSocket connected to Raspberry Pi!");
    } else if (event == WebsocketsEvent::ConnectionClosed) {
      Serial.println("[!] WebSocket disconnected.");
    }
  });

  bool ok = wsClient.connect(url);
  Serial.println(ok ? "[✓] WS connect OK" : "[!] WS connect retry scheduled");
}

void wsLoopOnce() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (!wsClient.available()) return;
  wsClient.poll();
}

// ------------------------------------------------------------------------------
// Send JPEG Frame via WebSocket
// ------------------------------------------------------------------------------
bool sendImageBufferWs(const uint8_t *buf, size_t len) {
  if (!wsClient.available()) return false;
  return wsClient.sendBinary((const char *)buf, len);
}

// ------------------------------------------------------------------------------
// Main Loop
// ------------------------------------------------------------------------------
void loop() {
  unsigned long now = millis();

  // 1. Check Serial input: pressing 'h' triggers immediate reconnect to Hotspot
  if (Serial.available()) {
    char ch = Serial.read();
    if (ch == 'h' || ch == 'H') {
      Serial.println("\n['h' received] Manually triggering reconnect to Raspberry Pi Hotspot...");
      active_ssid     = rpi_ssid;
      active_password = rpi_password;
      active_host     = rpi_host;
      connectWiFi(true);
    }
  }

  // 2. Wi-Fi & WebSocket Auto-Maintenance
  if (WiFi.status() != WL_CONNECTED) {
    // Retry Wi-Fi connection every 4 seconds without stalling the loop
    if (now - lastWifiCheckMs >= 4000) {
      lastWifiCheckMs = now;
      connectWiFi(false);
    }
  } else {
    // Ensure WebSocket is connected
    if (!wsClient.available()) {
      if (now - lastWsCheckMs >= 2500) {
        lastWsCheckMs = now;
        connectWebSocket();
      }
    }
  }

  // Keep WebSocket client active
  wsLoopOnce();

  // 3. Measure distance via Ultrasonic Sensor every 100 ms
  if (now - lastSensorCheckMs >= 100) {
    lastSensorCheckMs = now;
    float dist = measureDistanceCm();
    currentDistanceCm = dist;

    if (dist > 0.0 && dist < PROXIMITY_THRESHOLD_CM) {
      lastProximityTriggerMs = now;
      static unsigned long lastLog = 0;
      if (now - lastLog > 500) {
        Serial.printf("[ALERT] Proximity < 50cm! Distance: %.1f cm -> STREAMING\n", dist);
        lastLog = now;
      }
    }
  }

  // 4. Determine if streaming should be active
  bool proximityTriggerActive = (now - lastProximityTriggerMs <= PROXIMITY_HOLD_MS);
  bool shouldStream = proximityTriggerActive || reverseStreamingEnabled;

  if (shouldStream && wsClient.available()) {
    camera_fb_t *fb = esp_camera_fb_get();
    if (fb) {
      sendImageBufferWs(fb->buf, fb->len);
      esp_camera_fb_return(fb);
    }
    delay(10); // Yield slightly for network stability
  } else {
    delay(10); // Small idle delay
  }
}