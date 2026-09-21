import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:path/path.dart' as p;

Future<Response> handleUpload(Request request) async {
  print("upload handler called, method=${request.method}");
  if (request.method != 'POST') {
    return Response(
      405,
      body: jsonEncode({'error': 'Method Not Allowed'}),
      headers: {'content-type': 'application/json'},
    );
  }

  final contentType = request.headers['content-type'] ?? 'application/octet-stream';
  String suppliedName = request.headers['x-filename'] ?? request.url.queryParameters['name'] ?? '';
  String ext;
  if (contentType.contains('jpeg') || contentType.contains('jpg')) {
    ext = 'jpg';
  } else if (contentType.contains('png')) {
    ext = 'png';
  } else {
    ext = 'bin';
  }

  final uploadsDir = Directory('uploads');
  if (!await uploadsDir.exists()) await uploadsDir.create(recursive: true);

  final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '_');
  final baseName = suppliedName.isNotEmpty ? p.basenameWithoutExtension(suppliedName) : 'img_$timestamp';
  final filename = '$baseName.$ext';
  final file = File(p.join(uploadsDir.path, filename));
  IOSink? sink;
  try {
    sink = file.openWrite();

    // <-- The fix: cast the stream so pipe() sees Stream<List<int>> instead of Stream<Uint8List>
    await request.read().cast<List<int>>().pipe(sink);

    await sink.flush();
    await sink.close();

    final result = {'status': 'ok', 'filename': filename, 'path': file.path};
    print("Saved upload to ${file.path}");
    return Response(
      201,
      body: jsonEncode(result),
      headers: {'content-type': 'application/json'},
    );
  } catch (e, st) {
    print("Upload error: $e\n$st");
    if (sink != null) await sink.close();
    if (await file.exists()) await file.delete();
    final err = {'status': 'error', 'message': e.toString()};
    return Response.internalServerError(
      body: jsonEncode(err),
      headers: {'content-type': 'application/json'},
    );
  }
}

