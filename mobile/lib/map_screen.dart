import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'services/bluetooth_service.dart';
import 'widgets/bluetooth_modal.dart';

class SearchResult {
  final String displayName;
  final String name;
  final double lat;
  final double lon;

  SearchResult({
    required this.displayName,
    required this.name,
    required this.lat,
    required this.lon,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    return SearchResult(
      displayName: json['display_name'] ?? '',
      name: json['name'] ?? json['display_name']?.split(',').first ?? 'Location',
      lat: double.parse(json['lat'].toString()),
      lon: double.parse(json['lon'].toString()),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  
  // Default initial location: New York (or current user location when loaded)
  LatLng _currentCenter = const LatLng(40.7128, -74.0060);
  final double _initialZoom = 13.0;

  LatLng? _userLocation;
  LatLng? _selectedLocation;
  String? _selectedPlaceName;
  String? _selectedAddress;

  List<SearchResult> _searchResults = [];
  bool _isSearching = false;
  bool _isLoadingLocation = false;
  Timer? _debounceTimer;

  // Directions & Routing state
  List<LatLng> _routePoints = [];
  bool _isFetchingRoute = false;
  bool _hasActiveRoute = false;
  String? _routeDistance;
  String? _routeDuration;

  @override
  void initState() {
    super.initState();
    _checkInitialLocation();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // Attempt to fetch user position silently on start
  Future<void> _checkInitialLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        Position position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        );
        if (mounted) {
          setState(() {
            _userLocation = LatLng(position.latitude, position.longitude);
            _currentCenter = _userLocation!;
          });
          _mapController.move(_userLocation!, 15.0);
        }
      }
    } catch (_) {
      // Permission or location fetch silently ignored on launch
    }
  }

  // Current Location FAB handler
  Future<void> _goToCurrentLocation() async {
    setState(() {
      _isLoadingLocation = true;
    });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Location services are disabled. Please enable GPS.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Location permissions are denied.'),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Location permissions are permanently denied in settings.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      LatLng userLatLng = LatLng(position.latitude, position.longitude);
      setState(() {
        _userLocation = userLatLng;
        _selectedLocation = userLatLng;
        _selectedPlaceName = 'My Location';
        _selectedAddress = '${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}';
      });

      _mapController.move(userLatLng, 16.0);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error getting location: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingLocation = false;
        });
      }
    }
  }

  // OpenStreetMap Nominatim Search API
  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 400), () async {
      setState(() {
        _isSearching = true;
      });

      try {
        final uri = Uri.parse(
          'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(query)}&format=json&addressdetails=1&limit=6',
        );
        final response = await http.get(
          uri,
          headers: {'User-Agent': 'EbikeApp/1.0 (contact@ebike.app)'},
        );

        if (response.statusCode == 200) {
          final List data = json.decode(response.body);
          if (mounted) {
            setState(() {
              _searchResults = data.map((item) => SearchResult.fromJson(item)).toList();
            });
          }
        }
      } catch (e) {
        debugPrint('Search error: $e');
      } finally {
        if (mounted) {
          setState(() {
            _isSearching = false;
          });
        }
      }
    });
  }

  Future<void> _sendDestinationToEbike({
    required String name,
    required String address,
    required double lat,
    required double lon,
    String? distance,
    String? duration,
    bool showToast = true,
  }) async {
    final bt = EbikeBluetoothService.instance;
    if (bt.isConnected) {
      final success = await bt.sendMapLocation(
        name: name,
        address: address,
        lat: lat,
        lon: lon,
        distance: distance,
        duration: duration,
      );
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.bluetooth_connected, color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Opened "$name" on E-Bike Display!',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFF0066FF),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              duration: const Duration(seconds: 3),
            ),
          );
        } else {
          final errDetail = bt.lastError ?? 'Could not write to E-Bike control characteristic';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.amberAccent, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Failed to sync location to E-Bike',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    errDetail,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              action: SnackBarAction(
                label: 'VIEW LOGS',
                textColor: Colors.amberAccent,
                onPressed: () => bt.showLogsDialog(context),
              ),
              backgroundColor: const Color(0xFFB00020),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              duration: const Duration(seconds: 6),
            ),
          );
        }
      }
    } else {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.bluetooth_disabled, color: Colors.white70, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text('E-Bike display is not connected via Bluetooth'),
                ),
              ],
            ),
            action: SnackBarAction(
              label: 'LOGS',
              textColor: Colors.white,
              onPressed: () => bt.showLogsDialog(context),
            ),
            backgroundColor: const Color(0xFF333333),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Prompts the user to confirm whether they want to sync navigation with the E-Bike display
  Future<void> _promptSyncWithEbike({
    required String name,
    required String address,
    required double lat,
    required double lon,
    String? distance,
    String? duration,
  }) async {
    if (!mounted) return;
    final bt = EbikeBluetoothService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (bt.isConnected) {
      final shouldSync = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: isDark ? const Color(0xFF161B26) : Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (ctx) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0066FF).withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.pedal_bike_rounded,
                      color: Color(0xFF0066FF),
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Sync with E-Bike Display?',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Send "$name"${distance != null ? " ($distance • $duration)" : ""} to your E-Bike dashboard for real-time split-screen navigation.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white70 : Colors.black54,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            side: BorderSide(
                              color: isDark ? Colors.white24 : Colors.grey[300]!,
                            ),
                          ),
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(
                            'Phone Only',
                            style: TextStyle(
                              color: isDark ? Colors.white70 : Colors.black87,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0066FF),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            elevation: 2,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          icon: const Icon(Icons.sync_rounded, size: 20),
                          label: const Text(
                            'Sync to Bike',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );

      if (shouldSync == true && mounted) {
        _sendDestinationToEbike(
          name: name,
          address: address,
          lat: lat,
          lon: lon,
          distance: distance,
          duration: duration,
          showToast: true,
        );
      }
    } else {
      // E-Bike not connected - offer to pair
      final shouldConnect = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: isDark ? const Color(0xFF161B26) : Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (ctx) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.bluetooth_disabled_rounded,
                      color: Colors.orange,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'E-Bike Not Connected',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Route is ready on your phone! Connect your E-Bike via Bluetooth to mirror navigation on the bike screen.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white70 : Colors.black54,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            side: BorderSide(
                              color: isDark ? Colors.white24 : Colors.grey[300]!,
                            ),
                          ),
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(
                            'Phone Only',
                            style: TextStyle(
                              color: isDark ? Colors.white70 : Colors.black87,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0066FF),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            elevation: 2,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          icon: const Icon(Icons.bluetooth_searching_rounded, size: 20),
                          label: const Text(
                            'Pair E-Bike',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );

      if (shouldConnect == true && mounted) {
        BluetoothModal.show(context);
      }
    }
  }

  void _selectSearchResult(SearchResult result) {
    FocusScope.of(context).unfocus();
    final targetLatLng = LatLng(result.lat, result.lon);

    setState(() {
      _selectedLocation = targetLatLng;
      _selectedPlaceName = result.name;
      _selectedAddress = result.displayName;
      _searchResults = [];
      _searchController.text = result.name;
      // Reset active route when picking a new destination
      _clearRoute();
    });

    _mapController.move(targetLatLng, 15.0);
  }

  // Reverse geocode when map is tapped
  Future<void> _onMapTapped(LatLng point) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _selectedLocation = point;
      _selectedPlaceName = 'Selected Location';
      _selectedAddress = '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';
      _searchResults = [];
      _clearRoute();
    });

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=${point.latitude}&lon=${point.longitude}&format=json',
      );
      final response = await http.get(
        uri,
        headers: {'User-Agent': 'EbikeApp/1.0 (contact@ebike.app)'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted && _selectedLocation == point) {
          setState(() {
            _selectedPlaceName = data['name']?.isNotEmpty == true
                ? data['name']
                : (data['display_name']?.split(',').first ?? 'Selected Spot');
            _selectedAddress = data['display_name'] ?? _selectedAddress;
          });
        }
      }
    } catch (_) {}
  }

  // Fetch route and directions between user location (or center) and selected destination
  Future<void> _fetchDirections() async {
    if (_selectedLocation == null) return;
    
    final origin = _userLocation ?? _currentCenter;
    final destination = _selectedLocation!;

    setState(() {
      _isFetchingRoute = true;
    });

    try {
      // OSRM biking/cycling API request
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/cycling/${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}?overview=full&geometries=geojson',
      );
      final response = await http.get(
        url,
        headers: {'User-Agent': 'EbikeApp/1.0 (contact@ebike.app)'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final routes = data['routes'] as List;
        if (routes.isNotEmpty) {
          final route = routes[0];
          final double distanceMeters = (route['distance'] as num).toDouble();
          final double durationSeconds = (route['duration'] as num).toDouble();
          final List coords = route['geometry']['coordinates'];

          final List<LatLng> points = coords.map((c) {
            final List coordList = c as List;
            return LatLng(
              (coordList[1] as num).toDouble(),
              (coordList[0] as num).toDouble(),
            );
          }).toList();

          if (mounted) {
            setState(() {
              _routePoints = points;
              _routeDistance = '${(distanceMeters / 1000.0).toStringAsFixed(1)} km';
              _routeDuration = '${(durationSeconds / 60.0).round()} min';
              _hasActiveRoute = true;
              _isFetchingRoute = false;
            });

            _fitMapToBounds(origin, destination);

            // Ask user if they want to sync navigation to E-Bike display
            _promptSyncWithEbike(
              name: _selectedPlaceName ?? 'Destination',
              address: _selectedAddress ?? '',
              lat: destination.latitude,
              lon: destination.longitude,
              distance: _routeDistance,
              duration: _routeDuration,
            );
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('Error fetching route: $e');
    }

    // Fallback if API offline or fails: direct polyline
    if (mounted) {
      final distanceInMeters = Geolocator.distanceBetween(
        origin.latitude,
        origin.longitude,
        destination.latitude,
        destination.longitude,
      );
      final estDurationMin = ((distanceInMeters / 1000.0) / 20.0 * 60.0).round();

      setState(() {
        _routePoints = [origin, destination];
        _routeDistance = '${(distanceInMeters / 1000.0).toStringAsFixed(1)} km';
        _routeDuration = '${estDurationMin > 0 ? estDurationMin : 1} min';
        _hasActiveRoute = true;
        _isFetchingRoute = false;
      });

      _fitMapToBounds(origin, destination);

      // Ask user if they want to sync navigation to E-Bike display
      _promptSyncWithEbike(
        name: _selectedPlaceName ?? 'Destination',
        address: _selectedAddress ?? '',
        lat: destination.latitude,
        lon: destination.longitude,
        distance: _routeDistance,
        duration: _routeDuration,
      );
    }
  }

  void _fitMapToBounds(LatLng origin, LatLng destination) {
    try {
      final bounds = LatLngBounds.fromPoints([origin, destination]);
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(70.0),
        ),
      );
    } catch (_) {
      _mapController.move(destination, 14.0);
    }
  }

  void _clearRoute() {
    setState(() {
      _routePoints = [];
      _hasActiveRoute = false;
      _routeDistance = null;
      _routeDuration = null;
    });
  }

  void _zoomIn() {
    final currentZoom = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, currentZoom + 1);
  }

  void _zoomOut() {
    final currentZoom = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, currentZoom - 1);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        children: [
          // OpenStreetMap Widget
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentCenter,
              initialZoom: _initialZoom,
              onTap: (tapPosition, point) => _onMapTapped(point),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.mobile',
              ),
              // Polyline Layer for Navigation Directions Route
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      strokeWidth: 5.5,
                      color: const Color(0xFF0066FF),
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  // User GPS Location Marker (Blue Dot)
                  if (_userLocation != null)
                    Marker(
                      point: _userLocation!,
                      width: 50,
                      height: 50,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: 0.25),
                              shape: BoxShape.circle,
                            ),
                          ),
                          Container(
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(
                              color: Colors.blue,
                              shape: BoxShape.circle,
                              border: Border.fromBorderSide(
                                BorderSide(color: Colors.white, width: 3),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Selected Location Red Pin
                  if (_selectedLocation != null && _selectedLocation != _userLocation)
                    Marker(
                      point: _selectedLocation!,
                      width: 50,
                      height: 50,
                      alignment: Alignment.topCenter,
                      child: const Icon(
                        Icons.location_on,
                        color: Colors.redAccent,
                        size: 44,
                      ),
                    ),
                ],
              ),
            ],
          ),

          // Map Overlays safely contained within device SafeArea
          SafeArea(
            child: Stack(
              children: [
                // Top Search Bar with Back Button
                Positioned(
                  top: 12,
                  left: 16,
                  right: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Material(
                            elevation: 6,
                            shadowColor: Colors.black26,
                            shape: const CircleBorder(),
                            color: isDark ? const Color(0xFF242526) : Colors.white,
                            child: IconButton(
                              icon: const Icon(Icons.arrow_back),
                              color: isDark ? Colors.white : const Color(0xFF0066FF),
                              onPressed: () => Navigator.of(context).pop(),
                              tooltip: 'Back to E-Bike Home',
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Material(
                              elevation: 6,
                              shadowColor: Colors.black26,
                              borderRadius: BorderRadius.circular(28.0),
                              color: isDark ? const Color(0xFF242526) : Colors.white,
                              child: TextField(
                                controller: _searchController,
                                onChanged: _onSearchChanged,
                                decoration: InputDecoration(
                                  hintText: 'Search location on OpenStreetMap...',
                                  hintStyle: TextStyle(
                                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                                  ),
                                  prefixIcon: const Icon(Icons.search, color: Color(0xFF0066FF)),
                                  suffixIcon: _searchController.text.isNotEmpty
                                      ? IconButton(
                                          icon: const Icon(Icons.clear, color: Colors.grey),
                                          onPressed: () {
                                            _searchController.clear();
                                            _onSearchChanged('');
                                            _clearRoute();
                                          },
                                        )
                                      : null,
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 20.0,
                                    vertical: 15.0,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Material(
                            elevation: 6,
                            shadowColor: Colors.black26,
                            shape: const CircleBorder(),
                            color: isDark ? const Color(0xFF242526) : Colors.white,
                            child: IconButton(
                              icon: const Icon(Icons.receipt_long_rounded, size: 20),
                              color: const Color(0xFF0066FF),
                              onPressed: () => EbikeBluetoothService.instance.showLogsDialog(context),
                              tooltip: 'Bluetooth Logs',
                            ),
                          ),
                        ],
                      ),

                      // Search Results Overlay Card
                      if (_isSearching || _searchResults.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 8.0),
                          constraints: const BoxConstraints(maxHeight: 260),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF242526) : Colors.white,
                            borderRadius: BorderRadius.circular(16.0),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 10,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: _isSearching
                              ? const Padding(
                                  padding: EdgeInsets.all(20.0),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              : ListView.separated(
                                  shrinkWrap: true,
                                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                                  itemCount: _searchResults.length,
                                  separatorBuilder: (_, index) => const Divider(height: 1),
                                  itemBuilder: (context, index) {
                                    final item = _searchResults[index];
                                    return ListTile(
                                      leading: const Icon(
                                        Icons.place_outlined,
                                        color: Color(0xFF0066FF),
                                      ),
                                      title: Text(
                                        item.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                      subtitle: Text(
                                        item.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                                        ),
                                      ),
                                      onTap: () => _selectSearchResult(item),
                                    );
                                  },
                                ),
                        ),
                    ],
                  ),
                ),

                // Zoom Controls Stacked right
                Positioned(
                  right: 16,
                  bottom: _selectedLocation != null ? 220 : 80,
                  child: Column(
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'zoomInBtn',
                        backgroundColor: isDark ? const Color(0xFF242526) : Colors.white,
                        foregroundColor: isDark ? Colors.white : Colors.black87,
                        onPressed: _zoomIn,
                        child: const Icon(Icons.add),
                      ),
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'zoomOutBtn',
                        backgroundColor: isDark ? const Color(0xFF242526) : Colors.white,
                        foregroundColor: isDark ? Colors.white : Colors.black87,
                        onPressed: _zoomOut,
                        child: const Icon(Icons.remove),
                      ),
                    ],
                  ),
                ),

                // My Location FAB (Google Maps style)
                Positioned(
                  right: 16,
                  bottom: _selectedLocation != null ? 155 : 16,
                  child: FloatingActionButton(
                    heroTag: 'currentLocationBtn',
                    backgroundColor: const Color(0xFF0066FF),
                    foregroundColor: Colors.white,
                    elevation: 4,
                    onPressed: _isLoadingLocation ? null : _goToCurrentLocation,
                    child: _isLoadingLocation
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : const Icon(Icons.my_location),
                  ),
                ),

                // Bottom Google Maps style Place Card with Directions Button
                if (_selectedLocation != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: Card(
                      elevation: 8,
                      shadowColor: Colors.black38,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      color: isDark ? const Color(0xFF242526) : Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0066FF).withValues(alpha: 0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.location_on,
                                    color: Color(0xFF0066FF),
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _selectedPlaceName ?? 'Selected Location',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _selectedAddress ?? '',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close, color: Colors.grey),
                                  onPressed: () {
                                    setState(() {
                                      _selectedLocation = null;
                                      _selectedPlaceName = null;
                                      _selectedAddress = null;
                                      _clearRoute();
                                    });
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),

                            // Active Route Summary or Directions Action Button
                            if (_hasActiveRoute && _routeDistance != null) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0066FF).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: const Color(0xFF0066FF).withValues(alpha: 0.3),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.directions_bike,
                                      color: Color(0xFF0066FF),
                                      size: 24,
                                    ),
                                    const SizedBox(width: 10),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '$_routeDuration • $_routeDistance',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15,
                                            color: Color(0xFF0066FF),
                                          ),
                                        ),
                                        const Text(
                                          'Optimal E-Bike Route',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      tooltip: 'Sync with E-Bike Display',
                                      icon: const Icon(Icons.sync_rounded, color: Color(0xFF0066FF), size: 22),
                                      onPressed: () {
                                        if (_selectedLocation != null) {
                                          _promptSyncWithEbike(
                                            name: _selectedPlaceName ?? 'Destination',
                                            address: _selectedAddress ?? '',
                                            lat: _selectedLocation!.latitude,
                                            lon: _selectedLocation!.longitude,
                                            distance: _routeDistance,
                                            duration: _routeDuration,
                                          );
                                        }
                                      },
                                    ),
                                    TextButton.icon(
                                      onPressed: _clearRoute,
                                      icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
                                      label: const Text(
                                        'Clear',
                                        style: TextStyle(color: Colors.redAccent, fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ] else ...[
                              // Google Maps style Directions Button
                              SizedBox(
                                width: double.infinity,
                                height: 46,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF0066FF),
                                    foregroundColor: Colors.white,
                                    elevation: 2,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(24),
                                    ),
                                  ),
                                  onPressed: _isFetchingRoute ? null : _fetchDirections,
                                  icon: _isFetchingRoute
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.directions_rounded, size: 22),
                                  label: Text(
                                    _isFetchingRoute ? 'Calculating Route...' : 'Directions',
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
