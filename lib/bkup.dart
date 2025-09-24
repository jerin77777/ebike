import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math';

import 'package:ebike/widgets.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:rive/rive.dart' hide LinearGradient, Image;

import 'globals.dart';
import 'rasbperripi.dart';

import 'package:window_manager/window_manager.dart';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:flutter/material.dart' hide Router;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ----- start local server for uploads (in-memory) -----
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
    size: Size(800, 480),
    center: true,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  listen();

  runApp(const MyApp());
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
            // Text messages can be logged or used for status
            // No-op
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
/// Upload handler (in-memory)
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

    // Optionally you can inspect Content-Type if you want to validate image type:
    final contentType =
        request.headers['content-type'] ?? 'application/octet-stream';
    if (!(contentType.contains('jpeg') ||
        contentType.contains('jpg') ||
        contentType.contains('png') ||
        contentType.contains('image/'))) {
      // Not strictly required — we still forward bytes, but you can reject if desired.
      // For now, we still forward.
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
  late SimpleAnimation _simpleAnim;
  StreamSubscription<double>? speedSub;
  StreamSubscription<int>? speedModeSub;
  StreamSubscription<bool>? reverseSub;
  FocusNode focusNode = FocusNode();

  // Selected tab state
  String _selectedTab = 'SPORT';

  double _distanceKm = 12.4;

  // Show stream/fullscreen image
  bool _showStream = false;

  // Turn indicator state
  IndicatorDirection _indicatorDirection = IndicatorDirection.none;

  @override
  void initState() {
    super.initState();

    _simpleAnim = SimpleAnimation('Startup');

    // If you have a speedController stream in globals, attach to it safely
    try {
      speedSub = speedController.stream.listen((value) {
        speedInput?.change(value);
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
  }

  @override
  void dispose() {
    speedSub?.cancel();
    speedModeSub?.cancel();
    reverseSub?.cancel();
    super.dispose();
  }

  void _onRiveInit(Artboard artboard) {
    _stateMachineController = StateMachineController.fromArtboard(
      artboard,
      'State Machine 1',
    );
    if (_stateMachineController != null) {
      artboard.addController(_stateMachineController!);

      for (final input in _stateMachineController!.inputs) {
        if (input is SMINumber) {
          speedInput = input;
          break;
        }
      }
    } else {
      artboard.addController(_simpleAnim);
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.keyQ) {
        exit(0);
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        setState(() => _indicatorDirection = IndicatorDirection.left);
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        setState(() => _indicatorDirection = IndicatorDirection.right);
      }
      if (event.logicalKey == LogicalKeyboardKey.space) {
        setState(() => _indicatorDirection = IndicatorDirection.none);
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
              // If stream mode is on show StreamViewWrapper full screen, otherwise show the normal UI.
              if (_showStream)
                const Positioned.fill(child: StreamViewWrapper())
              else ...[
                Center(
                  child: SizedBox(
                    width: 700,
                    height: 700,
                    child: RiveAnimation.asset(
                      'assets/speedometer.riv',
                      onInit: _onRiveInit,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                ModeTabs(
                  selectedTab: _selectedTab,
                  onTabChanged: (tab) => setState(() => _selectedTab = tab),
                ),
                const Positioned(top: 8, left: 8, child: TimeWidget()),
                Positioned(
                  top: 8,
                  right: 8,
                  child: BatteryWidget(
                    initialPercent: 87,
                    updateInterval: const Duration(seconds: 5),
                    onChanged: (p) {},
                  ),
                ),
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
                child: TurnIndicatorBar(direction: _indicatorDirection),
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
