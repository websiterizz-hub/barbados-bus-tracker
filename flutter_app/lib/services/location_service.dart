import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../models/app_models.dart';

final locationServiceProvider = Provider<LocationService>((ref) {
  return GeolocatorLocationService();
});

abstract class LocationService {
  Future<LocationLookup> getCurrentLocation();
  Future<bool> openAppSettings();
  Future<bool> openLocationSettings();
}

class GeolocatorLocationService implements LocationService {
  @override
  Future<LocationLookup> getCurrentLocation() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        return const LocationLookup(
          status: LocationStatus.serviceDisabled,
          message: 'Location services are turned off on this device.',
        );
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return const LocationLookup(
          status: LocationStatus.permissionDenied,
          message:
              'Location permission denied. Use search or recent stops instead.',
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 10),
        ),
      );

      return LocationLookup(
        status: LocationStatus.available,
        position: SavedLocation(
          lat: position.latitude,
          lng: position.longitude,
        ),
      );
    } catch (error) {
      return LocationLookup(
        status: LocationStatus.error,
        message: error.toString(),
      );
    }
  }

  @override
  Future<bool> openAppSettings() {
    return Geolocator.openAppSettings();
  }

  @override
  Future<bool> openLocationSettings() {
    return Geolocator.openLocationSettings();
  }
}
