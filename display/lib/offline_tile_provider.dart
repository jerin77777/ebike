import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// Offline Tile Provider specifically built for Coimbatore City, Tamil Nadu.
/// Loads pre-bundled raster tiles directly from the Flutter asset bundle or
/// local filesystem with zero latency and zero internet requirement.
class CoimbatoreOfflineTileProvider extends TileProvider {
  final bool enableNetworkFallback;

  CoimbatoreOfflineTileProvider({
    this.enableNetworkFallback = false,
  });

  /// Check whether the tile coordinates fall within the downloaded Coimbatore offline map bounds
  static bool isCoimbatoreTile(int z, int x, int y) {
    switch (z) {
      case 10:
        return (x >= 730 && x <= 731) && (y >= 480 && y <= 480);
      case 11:
        return (x >= 1461 && x <= 1462) && (y >= 960 && y <= 961);
      case 12:
        return (x >= 2922 && x <= 2924) && (y >= 1920 && y <= 1923);
      case 13:
        return (x >= 5844 && x <= 5849) && (y >= 3841 && y <= 3846);
      case 14:
        return (x >= 11689 && x <= 11699) && (y >= 7682 && y <= 7692);
      case 15:
        return (x >= 23379 && x <= 23399) && (y >= 15365 && y <= 15385);
      default:
        return false;
    }
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final z = coordinates.z;
    final x = coordinates.x;
    final y = coordinates.y;

    if (isCoimbatoreTile(z, x, y)) {
      // 1. Try local filesystem if running standalone on Raspberry Pi / Linux
      final localPaths = [
        'assets/tiles/${z}_${x}_$y.png',
        'display/assets/tiles/${z}_${x}_$y.png',
        '/home/ebike/ebike/display/assets/tiles/${z}_${x}_$y.png',
      ];
      for (final p in localPaths) {
        final f = File(p);
        if (f.existsSync()) {
          return FileImage(f);
        }
      }

      // 2. Primary: Flutter Asset Bundle (packaged in app build)
      return AssetImage('assets/tiles/${z}_${x}_$y.png');
    }

    // If outside Coimbatore bounds and network fallback is permitted (e.g. testing)
    if (enableNetworkFallback) {
      final networkUrl = getTileUrl(coordinates, options);
      return NetworkImage(networkUrl, headers: options.additionalOptions);
    }

    // Completely offline fallback: Return transparent 1x1 image so FlutterMap
    // doesn't crash or show broken network tile errors
    return MemoryImage(TileProvider.transparentImage);
  }
}
