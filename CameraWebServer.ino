// ESP32-CAM: capture a fresh image each time and upload to Dart server
// Replace SSID/PASSWORD and dartServerHost with your values.
// Keep startCameraServer() and setupLedFlash() provided elsewhere if you use them.

#include "esp_camera.h"
#include <WiFi.h>
#include <WiFiClient.h>
#include <ArduinoWebsockets.h>
#include "board_config.h" // camera pin definitions

// --------------------
// WiFi and server info
// --------------------
const char *ssid = "test";
const char *password = "";

const char* dartServerHost = "192.168.1.100"; // <-- set your PC LAN IP
const uint16_t dartServerWsPort = 5001;
const char* dartServerWsPath = "/ws";

// Prototypes (may be provided elsewhere)
void startCameraServer();
void setupLedFlash();
void wsLoopOnce();

// ----------------------------
// Camera + WiFi initialization
// ----------------------------
void setup() {
  Serial.begin(115200);
  Serial.setDebugOutput(true);
  Serial.println();
  Serial.println("ESP32-CAM starting...");

  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_UXGA;
  config.grab_mode = CAMERA_GRAB_WHEN_EMPTY;
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.jpeg_quality = 12;
  config.fb_count = 1;

  if (config.pixel_format == PIXFORMAT_JPEG) {
    if (psramFound()) {
      config.jpeg_quality = 10;
      config.fb_count = 2;
      config.grab_mode = CAMERA_GRAB_LATEST;
    } else {
      config.frame_size = FRAMESIZE_SVGA;
      config.fb_location = CAMERA_FB_IN_DRAM;
    }
  } else {
    config.frame_size = FRAMESIZE_240X240;
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init failed with error 0x%x\n", err);
    while(true) delay(1000);
  }

  sensor_t * s = esp_camera_sensor_get();
  if (s->id.PID == OV3660_PID) {
    s->set_vflip(s, 1);
    s->set_brightness(s, 1);
    s->set_saturation(s, -2);
  }
  s->set_framesize(s, FRAMESIZE_QVGA);

#if defined(LED_GPIO_NUM)
  setupLedFlash();
#endif

  // Connect WiFi
  WiFi.begin(ssid, password);
  WiFi.setAutoReconnect(true);
  Serial.print("Connecting to WiFi");
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 30000) {
    Serial.print(".");
    delay(500);
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.println();
    Serial.print("WiFi connected, IP: ");
    Serial.println(WiFi.localIP());
    connectWebSocket();
  } else {
    Serial.println();
    Serial.println("WiFi connection failed (continuing; will retry before each upload)");
  }

  // Optional: start camera web server if you have it in the project
  startCameraServer();
  Serial.println("Setup complete.");
}

// --------------------------------------------------
// Sends a supplied buffer (JPEG bytes) to the Dart server
// --------------------------------------------------
using namespace websockets;

WebsocketsClient wsClient;
volatile bool streamingEnabled = false;

bool sendImageBufferWs(const uint8_t* buf, size_t len) {
  if (!wsClient.available()) return false;
  // Send as binary; library handles fragmentation
  bool ok = wsClient.sendBinary((const char*)buf, len);
  if (!ok) {
    Serial.println("WS sendBinary failed");
  }
  return ok;
}

// -----------------------------
// Main loop: capture then send
// -----------------------------
void loop() {
  // maintain WiFi
  if (WiFi.status() != WL_CONNECTED) {
    WiFi.reconnect();
    delay(100);
  }

  // ensure WS connection
  if (!wsClient.available() && WiFi.status() == WL_CONNECTED) {
    static unsigned long lastTry = 0;
    unsigned long now = millis();
    if (now - lastTry > 2000) { // try every 2s
      connectWebSocket();
      lastTry = now;
    }
  }

  // keep websockets processing alive
  wsLoopOnce();

  if (!streamingEnabled) {
    delay(10);
    return;
  }

  camera_fb_t * fb = esp_camera_fb_get();
  if (!fb) {
    Serial.println("Camera capture failed — fb is NULL");
    delay(10);
    return;
  }

  sendImageBufferWs(fb->buf, fb->len);
  esp_camera_fb_return(fb);

  // small delay to yield; adjust for rate
  delay(5);
}

void wsLoopOnce() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (!wsClient.available()) return;
  wsClient.poll();
}

void connectWebSocket() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (wsClient.available()) return;

  String url = String("ws://") + dartServerHost + ":" + String(dartServerWsPort) + dartServerWsPath;
  Serial.println("Connecting WS to " + url);

  wsClient.onMessage([&](WebsocketsMessage message) {
    if (message.isText()) {
      String text = message.data();
      text.toLowerCase();
      if (text == "start") {
        streamingEnabled = true;
        Serial.println("WS command: start");
      } else if (text == "stop") {
        streamingEnabled = false;
        Serial.println("WS command: stop");
      }
    }
  });

  wsClient.onEvent([&](WebsocketsEvent event, String data) {
    if (event == WebsocketsEvent::ConnectionOpened) {
      Serial.println("WS connected");
    } else if (event == WebsocketsEvent::ConnectionClosed) {
      Serial.println("WS disconnected");
    } else if (event == WebsocketsEvent::GotPing) {
      Serial.println("WS ping");
    } else if (event == WebsocketsEvent::GotPong) {
      Serial.println("WS pong");
    }
  });

  bool ok = wsClient.connect(url);
  Serial.println(ok ? "WS connect OK" : "WS connect FAIL");
}
