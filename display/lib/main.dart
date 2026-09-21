import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'widgets.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:rive/rive.dart' hide Image;

import 'globals.dart';
import 'raspberrypi.dart';
import 'navigation_widget.dart';

import 'package:window_manager/window_manager.dart';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:flutter/material.dart' hide Router;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ----- start local server for uploads (in-memory) for ESP camera -----
  const Map<String, String> corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Origin, Content-Type, X-Filename, Accept',
  };

  Response? optionsHandler(Request request) {
    if (request.method == 'OPTIONS') {
      return Response.ok('', headers: corsHeaders);
    }
    return null;
  }

  Response addCorsHeaders(Response response) =>
      response.change(headers: {...response.headers, ...corsHeaders});

  final corsMiddleware = createMiddleware(
    requestHandler: optionsHandler,
    responseHandler: addCorsHeaders,
  );

  final router = Router()..post('/upload', (Request req) => handleUpload(req));

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware)
      .addHandler(router);

  final server = await io.serve(handler, InternetAddress.anyIPv4, 5000);
  print('Server listening on http://${server.address.address}:${server.port}');

  // ----- start WebSocket server for streaming (binary frames) -----
  await _startWebSocketServer(
    address: InternetAddress.anyIPv4,
    port: 5001,
    path: '/ws',
  );

  // ----- initialize window manager (desktop) -----
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    titleBarStyle: TitleBarStyle.hidden,
    size: Size(1024, 650),
    center: true,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  listen();

  turnOnBluetooth();

  HostState.checkInitialStatus();

  runApp(const MyApp());
}

/// Simple Bluetooth turn-on helper
void turnOnBluetooth() async {
  if (!Platform.isLinux) return;
  try {
    final script = File('auto_on_bluetooth.sh').existsSync()
        ? 'auto_on_bluetooth.sh'
        : 'display/auto_on_bluetooth.sh';
    final res = await Process.run('bash', [script]);
    print(res.stdout);
    if (res.exitCode != 0) print(res.stderr);
  } catch (e) {
    print('Bluetooth error: $e');
  }
}

/// ---------------------------
/// Global in-memory image stream
/// ---------------------------
/// Broadcast so multiple widgets can listen if needed.
final StreamController<Uint8List> imageStreamController =
    StreamController<Uint8List>.broadcast();

/// ---------------------------
/// WebSocket streaming server
/// - Accepts upgrades on /ws
/// - Receives binary frames and forwards to imageStreamController
/// - Broadcasts 'start'/'stop' to all clients when reverseController changes
/// ---------------------------
final Set<WebSocket> _wsClients = <WebSocket>{};
bool _lastReverse = false;

/// Broadcasts telemetry updates to connected clients (like ebike_bluetooth_host.py)
void broadcastTelemetry({
  double? speed,
  String? mode,
  String? lights,
  String? indicator,
  bool? reverse,
}) {
  final Map<String, dynamic> data = {};
  if (speed != null) data['speed'] = speed;
  if (mode != null) data['mode'] = mode;
  if (lights != null) data['lights'] = lights;
  if (indicator != null) data['indicator'] = indicator;
  if (reverse != null) data['reverse'] = reverse;
  if (data.isEmpty) return;

  final payload = jsonEncode(data);
  for (final ws in _wsClients.toList()) {
    try {
      ws.add(payload);
    } catch (_) {
      _wsClients.remove(ws);
    }
  }
}

Future<void> _startWebSocketServer({
  required InternetAddress address,
  required int port,
  String path = '/ws',
}) async {
  final httpServer = await HttpServer.bind(address, port);
  print(
    'WebSocket server listening on ws://${httpServer.address.address}:$port$path',
  );

  // Forward reverse state changes to all connected clients as 'start'/'stop'
  reverseController.stream.listen((bool isReverse) {
    _lastReverse = isReverse;
    final String cmd = isReverse ? 'start' : 'stop';
    broadcastTelemetry(reverse: isReverse);
    for (final ws in _wsClients.toList()) {
      try {
        ws.add(cmd);
      } catch (_) {
        _wsClients.remove(ws);
        try {
          ws.close();
        } catch (_) {}
      }
    }
  });

  httpServer.listen((HttpRequest request) async {
    if (request.uri.path != path) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    try {
      final ws = await WebSocketTransformer.upgrade(request);
      _wsClients.add(ws);
      // Send current reverse state to new client
      ws.add(_lastReverse ? 'start' : 'stop');
      ws.listen(
        (dynamic data) {
          // If client sends binary frames, forward to UI
          if (data is List<int>) {
            imageStreamController.add(Uint8List.fromList(data));
          } else if (data is String) {
            try {
              final parsed = jsonDecode(data);
              if (parsed is Map<String, dynamic>) {
                if (parsed['type'] == 'bluetooth_status') {
                  final statusStr = parsed['status'];
                  final dev = parsed['device_name'] as String?;
                  BtConnectionState st = BtConnectionState.disconnected;
                  if (statusStr == 'advertising') {
                    st = BtConnectionState.advertising;
                  } else if (statusStr == 'connected') {
                    st = BtConnectionState.connected;
                  }
                  BluetoothState.update(st, dev);
                } else if (parsed['source'] == 'mobile_bluetooth' && parsed['command'] != null) {
                  final cmd = parsed['command'];
                  final action = cmd['action'] ?? cmd['cmd'];
                  final val = cmd['val'] ?? cmd['value'];

                  // Any command from mobile means phone is connected!
                  final phoneName = (val is Map && val['device_name'] != null)
                      ? val['device_name'].toString()
                      : (BluetoothState.connectedDevice ?? 'Phone');
                  if (BluetoothState.currentStatus != BtConnectionState.connected) {
                    BluetoothState.update(BtConnectionState.connected, phoneName);
                  }

                  if (action == 'phone_connected' || action == 'phone_sync') {
                    BluetoothState.update(BtConnectionState.connected, phoneName);
                  } else if (action == 'set_mode') {
                    int m = 1;
                    final vStr = val.toString().toUpperCase();
                    if (vStr == 'CRUISE' || vStr == 'CITY') {
                      m = 2;
                    } else if (vStr == 'SPORT' || vStr == 'TURBO') {
                      m = 3;
                    }
                    speedModeController.add(m);
                  } else if (action == 'set_lights') {
                    lightController.add(val.toString());
                  } else if (action == 'open_map' || action == 'navigate_to' || action == 'set_destination') {
                    NavigationState.openMap(MapDestination.fromDynamic(val));
                  }
                }
              }
            } catch (_) {}
          }
        },
        onError: (_) {
          _wsClients.remove(ws);
        },
        onDone: () {
          _wsClients.remove(ws);
        },
        cancelOnError: true,
      );
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('WS upgrade failed');
        await request.response.close();
      } catch (_) {}
    }
  });
}

/// ---------------------------
/// Upload handler (in-memory) for ESP camera
/// Accepts raw image bytes in the POST body (Content-Type: image/jpeg|png ...)
/// and emits the bytes on imageStreamController. Does NOT save to disk.
/// ---------------------------
Future<Response> handleUpload(Request request) async {
  print("upload handler called, method=${request.method}");
  if (request.method != 'POST') {
    return Response(
      405,
      body: jsonEncode({'error': 'Method Not Allowed'}),
      headers: {'content-type': 'application/json'},
    );
  }

  try {
    // Read entire request body into memory safely (using BytesBuilder)
    final bb = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      bb.add(chunk);
    }
    final bytes = bb.toBytes();

    if (bytes.isEmpty) {
      return Response(
        400,
        body: jsonEncode({'status': 'error', 'message': 'Empty body'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // Emit into the in-memory stream for immediate UI display
    imageStreamController.add(Uint8List.fromList(bytes));

    final result = {
      'status': 'ok',
      'message': 'Image received',
      'size': bytes.length,
    };
    print("Received upload (${bytes.length} bytes), emitted to image stream");
    return Response(
      201,
      body: jsonEncode(result),
      headers: {'content-type': 'application/json'},
    );
  } catch (e, st) {
    print("Upload error: $e\n$st");
    final err = {'status': 'error', 'message': e.toString()};
    return Response.internalServerError(
      body: jsonEncode(err),
      headers: {'content-type': 'application/json'},
    );
  }
}

/// ---------------------------
/// App
/// ---------------------------
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Curved + Linear Tachometer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        textTheme: GoogleFonts.spaceGroteskTextTheme(
          TextTheme(
            displayLarge: TextStyle(color: Pallet.font1),
            displayMedium: TextStyle(color: Pallet.font1),
            bodyMedium: TextStyle(color: Pallet.font1),
            titleMedium: TextStyle(color: Pallet.font1),
          ),
        ),
      ),
      home: const Interface(),
    );
  }
}

/// ---------------------------
/// Main Interface
/// ---------------------------
class Interface extends StatefulWidget {
  const Interface({super.key});

  @override
  State<Interface> createState() => _InterfaceState();
}

class _InterfaceState extends State<Interface> {
  StateMachineController? _stateMachineController;
  SMINumber? speedInput;
  StreamSubscription<double>? speedSub;
  StreamSubscription<int>? speedModeSub;
  StreamSubscription<bool>? reverseSub;
  FocusNode focusNode = FocusNode();

  // Selected tab state
  String _selectedTab = 'SPORT';

  // Show stream/fullscreen image
  bool _showStream = false;
  StreamSubscription<Uint8List>? imageStreamSub;
  Timer? _streamAutoHideTimer;

  // Show map / navigation screen
  bool _showMap = false;
  StreamSubscription<bool>? _navSub;

  // Phone Connected notification banner
  bool _showPhoneConnectedBanner = false;
  String _connectedPhoneName = 'Phone';
  Timer? _phoneBannerTimer;
  StreamSubscription<BtConnectionState>? _btStateSub;

  // Turn indicator state
  IndicatorDirection _indicatorDirection = IndicatorDirection.none;
  LightBeam _beam = LightBeam.low;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);

    // If you have a speedController stream in globals, attach to it safely
    try {
      speedSub = speedController.stream.listen((value) {
        speedInput?.value = value;
        broadcastTelemetry(speed: value);
      });
    } catch (e) {
      // ignore if speedController isn't present
    }

    // Listen to Raspberry Pi speed mode and reflect in ModeTabs
    try {
      speedModeSub = speedModeController.stream.listen((mode) {
        String tab;
        switch (mode) {
          case 2:
            tab = 'CRUISE';
            break;
          case 3:
            tab = 'SPORT';
            break;
          case 1:
          default:
            tab = 'ECO';
        }
        if (tab != _selectedTab) {
          setState(() => _selectedTab = tab);
        }
        broadcastTelemetry(mode: tab);
      });
    } catch (e) {
      // ignore if speedModeController isn't present
    }

    // Listen to Raspberry Pi reverse state and toggle stream view
    try {
      reverseSub = reverseController.stream.listen((bool isReverse) {
        _setShowStream(isReverse);
      });
    } catch (e) {
      // ignore if reverseController isn't present
    }

    // Listen to Raspberry Pi light beam state
    try {
      lightController.stream.listen((String mode) {
        final LightBeam next = (mode == 'high_beam')
            ? LightBeam.high
            : LightBeam.low;
        if (next != _beam) {
          setState(() => _beam = next);
        }
        broadcastTelemetry(lights: mode);
      });
    } catch (e) {
      // ignore if lightController isn't present
    }

    // Listen to Raspberry Pi indicator state
    try {
      indicatorController.stream.listen((String dir) {
        IndicatorDirection next;
        switch (dir) {
          case 'left':
            next = IndicatorDirection.left;
            break;
          case 'right':
            next = IndicatorDirection.right;
            break;
          case 'none':
          default:
            next = IndicatorDirection.none;
        }
        if (next != _indicatorDirection) {
          setState(() => _indicatorDirection = next);
        }
        broadcastTelemetry(indicator: dir);
      });
    } catch (e) {
      // ignore if indicatorController isn't present
    }

    // Listen to incoming camera stream frames (e.g. proximity <50cm trigger)
    try {
      imageStreamSub = imageStreamController.stream.listen((_) {
        if (!_showStream) {
          _setShowStream(true);
        }
        _streamAutoHideTimer?.cancel();
        _streamAutoHideTimer = Timer(const Duration(milliseconds: 2000), () {
          if (!_lastReverse && mounted) {
            _setShowStream(false);
          }
        });
      });
    } catch (e) {
      // ignore
    }

    // Listen to Navigation state (e.g. phone searched location)
    try {
      _navSub = NavigationState.activeController.stream.listen((active) {
        if (mounted) {
          setState(() => _showMap = active);
        }
      });
    } catch (_) {}

    // Listen to Bluetooth phone connection state to show connected banner
    try {
      _btStateSub = BluetoothState.statusController.stream.listen((state) {
        if (state == BtConnectionState.connected && mounted) {
          final phone = BluetoothState.connectedDevice ?? 'Phone';
          setState(() {
            _showPhoneConnectedBanner = true;
            _connectedPhoneName = phone;
          });
          _phoneBannerTimer?.cancel();
          _phoneBannerTimer = Timer(const Duration(milliseconds: 3500), () {
            if (mounted) {
              setState(() => _showPhoneConnectedBanner = false);
            }
          });
        } else if (mounted) {
          setState(() => _showPhoneConnectedBanner = false);
        }
      });
    } catch (_) {}
  }

  void _onRiveInit(Artboard artboard) {
    final controller = StateMachineController.fromArtboard(
      artboard,
      'State Machine 1',
    );
    if (controller != null) {
      artboard.addController(controller);
      _stateMachineController = controller;
      for (final input in controller.inputs) {
        if (input is SMINumber) {
          speedInput = input;
          break;
        }
      }
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _phoneBannerTimer?.cancel();
    _btStateSub?.cancel();
    _navSub?.cancel();
    _streamAutoHideTimer?.cancel();
    imageStreamSub?.cancel();
    speedSub?.cancel();
    speedModeSub?.cancel();
    reverseSub?.cancel();
    _stateMachineController?.dispose();
    focusNode.dispose();
    super.dispose();
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.keyQ) {
        exit(0);
      } else if (event.logicalKey == LogicalKeyboardKey.keyH) {
        HostState.toggle();
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.keyM) {
        NavigationState.toggle();
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (_showMap) {
          NavigationState.closeMap();
          return true;
        }
      }
    }
    return false;
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.keyQ) {
        exit(0);
      } else if (event.logicalKey == LogicalKeyboardKey.keyH) {
        HostState.toggle();
      } else if (event.logicalKey == LogicalKeyboardKey.keyM) {
        NavigationState.toggle();
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (_showMap) {
          NavigationState.closeMap();
        }
      }
    }
  }

  // Public setter used by StreamViewWrapper via context.findAncestorStateOfType
  void _setShowStream(bool show) {
    setState(() => _showStream = show);
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: focusNode,
      onKeyEvent: _handleKeyEvent,
      autofocus: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
                // If stream mode is on show StreamViewWrapper full screen, otherwise show map or normal UI.
                if (_showStream)
                  const Positioned.fill(child: StreamViewWrapper())
                else if (_showMap && NavigationState.currentDestination != null)
                  Positioned.fill(
                    child: EbikeNavigationWidget(
                      destination: NavigationState.currentDestination!,
                      onClose: () => NavigationState.closeMap(),
                    ),
                  )
                else ...[
                  Center(
                    child: SizedBox(
                      width: 650,
                      height: 650,
                      child: RiveAnimation.asset(
                        'assets/speedometer.riv',
                        fit: BoxFit.cover,
                        onInit: _onRiveInit,
                      ),
                    ),
                  ),
                  ModeTabs(
                    selectedTab: _selectedTab,
                    onTabChanged: (tab) => setState(() => _selectedTab = tab),
                  ),
                  Positioned(
                    top: 10,
                    left: 12,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        TimeWidget(),
                        SizedBox(width: 16),
                        TemperatureWidget(),
                        SizedBox(width: 16),
                        BluetoothStatusWidget(),
                      ],
                    ),
                  ),
                  Positioned(
                    top: 10,
                    right: 12,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (NavigationState.currentDestination != null) ...[
                          GestureDetector(
                            onTap: () => NavigationState.openMap(NavigationState.currentDestination!),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0066FF).withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFF0066FF)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.navigation, color: Color(0xFF3399FF), size: 14),
                                  const SizedBox(width: 4),
                                  Text(
                                    NavigationState.currentDestination!.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        const HostIndicatorWidget(),
                        const SizedBox(width: 10),
                        const SmokeSensorWidget(),
                      ],
                    ),
                  ),
                  // Removed separate BeamIndicator; now shown in TurnIndicatorBar
                ],
                // Indicator bar overlays at the very bottom regardless of mode
                const Positioned.fill(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: SizedBox.shrink(),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: TurnIndicatorBar(
                    direction: _indicatorDirection,
                    beam: _beam,
                  ),
                ),

                // Animated Phone Connected Notification Banner
                if (_showPhoneConnectedBanner)
                  Positioned(
                    top: 50,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xEE0B1220),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF00E676), width: 1.5),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF00E676).withValues(alpha: 0.35),
                              blurRadius: 16,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(5),
                              decoration: const BoxDecoration(
                                color: Color(0xFF00E676),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.check, color: Colors.black, size: 14),
                            ),
                            const SizedBox(width: 10),
                            const Icon(Icons.smartphone_rounded, color: Color(0xFF00E5FF), size: 20),
                            const SizedBox(width: 8),
                            Text(
                              'Phone Connected: $_connectedPhoneName',
                              style: GoogleFonts.spaceGrotesk(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
    );
  }
}

/// ---------------------------
/// StreamViewWrapper (in-memory)
/// Listens to imageStreamController and shows the latest bytes via Image.memory.
/// ---------------------------
class StreamViewWrapper extends StatefulWidget {
  const StreamViewWrapper({super.key});

  @override
  State<StreamViewWrapper> createState() => _StreamViewWrapperState();
}

class _StreamViewWrapperState extends State<StreamViewWrapper> {
  Uint8List? _latestBytes;
  StreamSubscription<Uint8List>? _sub;

  @override
  void initState() {
    super.initState();
    // Subscribe to the global image stream:
    _sub = imageStreamController.stream.listen(
      (bytes) {
        // Update UI immediately when bytes arrive
        setState(() {
          _latestBytes = bytes;
        });
      },
      onError: (e) {
        // ignore
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
          Positioned.fill(
            child: _latestBytes != null
                ? Image.memory(
                    _latestBytes!,
                    fit: BoxFit.cover,
                    gaplessPlayback:
                        true, // helps avoid flicker when bytes update quickly
                  )
                : Container(
                    color: Colors.black,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.photo, size: 96, color: Colors.white24),
                          SizedBox(height: 12),
                          Text(
                            'Waiting for image stream...',
                            style: TextStyle(color: Colors.white38),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),

          // Close button
          Positioned(
            top: 12,
            left: 12,
            child: SafeArea(
              minimum: const EdgeInsets.all(4),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black54,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onPressed: () {
                  final state = context
                      .findAncestorStateOfType<_InterfaceState>();
                  state?._setShowStream(false);
                },
                child: const Text('Close', style: TextStyle(color: Colors.white)),
              ),
            ),
          ),
        ],
      );
  }
}
