import 'package:flutter_test/flutter_test.dart';
import 'package:display/globals.dart';
import 'package:display/offline_tile_provider.dart';

void main() {
  group('Coimbatore Offline Map Tests', () {
    test('Verifies Coimbatore default destination coordinates', () {
      final dest = NavigationState.defaultCoimbatore;
      expect(dest.name, 'Coimbatore City');
      expect(dest.lat, closeTo(11.0168, 0.001));
      expect(dest.lon, closeTo(76.9558, 0.001));
    });

    test('Verifies Coimbatore tile coordinate boundary checks for all zoom levels', () {
      // Zoom 10
      expect(CoimbatoreOfflineTileProvider.isCoimbatoreTile(10, 730, 480), isTrue);
      expect(CoimbatoreOfflineTileProvider.isCoimbatoreTile(10, 731, 480), isTrue);
      expect(CoimbatoreOfflineTileProvider.isCoimbatoreTile(10, 732, 480), isFalse);

      // Zoom 12 (Coimbatore City center ~ 2923, 1921)
      expect(CoimbatoreOfflineTileProvider.isCoimbatoreTile(12, 2923, 1921), isTrue);
      expect(CoimbatoreOfflineTileProvider.isCoimbatoreTile(12, 100, 100), isFalse);

      // Zoom 15 (Peelamedu, RS Puram, Gandhipuram)
      expect(CoimbatoreOfflineTileProvider.isCoimbatoreTile(15, 23380, 15370), isTrue);
      expect(CoimbatoreOfflineTileProvider.isCoimbatoreTile(15, 23399, 15385), isTrue);
      expect(CoimbatoreOfflineTileProvider.isCoimbatoreTile(15, 23400, 15386), isFalse);

      // Out of range zoom
      expect(CoimbatoreOfflineTileProvider.isCoimbatoreTile(9, 365, 240), isFalse);
      expect(CoimbatoreOfflineTileProvider.isCoimbatoreTile(16, 46758, 30740), isFalse);
    });

    test('NavigationState defaults to Coimbatore when toggled offline', () {
      NavigationState.currentDestination = null;
      NavigationState.isNavigating = false;

      NavigationState.toggle();

      expect(NavigationState.isNavigating, isTrue);
      expect(NavigationState.currentDestination?.name, 'Coimbatore City');
      expect(NavigationState.currentDestination?.lat, closeTo(11.0168, 0.001));

      // Close navigation
      NavigationState.toggle();
      expect(NavigationState.isNavigating, isFalse);
    });
  });
}
