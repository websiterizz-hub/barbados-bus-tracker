import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../models/app_models.dart';

final locationServiceProvider = Provider<LocationService>((ref) {
  return GeolocatorLocationService();
});

abstract class LocationService {
  Future<LocationLookup> getCurrentLocation({bool forcePrompt = false});
  Future<bool> openAppSettings();
  Future<bool> openLocationSettings();
}

class GeolocatorLocationService implements LocationService {
  @override
  Future<LocationLookup> getCurrentLocation({bool forcePrompt = false}) async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        return const LocationLookup(
          status: LocationStatus.serviceDisabled,
          message: 'Location services are turned off on this device.',
        );
      }

      var permission = await Geolocator.checkPermission();
      
      // On Web, 'denied' often means 'prompt required'.
      // We only prompt if forcePrompt is true (triggered by user gesture).
      if (permission == LocationPermission.denied) {
        if (forcePrompt) {
          permission = await Geolocator.requestPermission();
        } else {
          // Passive mode: return available status but without a position 
          // if permission isn't already granted.
          return const LocationLookup(
            status: LocationStatus.available,
            message: 'GPS standby: Tap locate icon to enable live tracking.',
          );
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return const LocationLookup(
          status: LocationStatus.permissionDenied,
          message:
              'Location permission permanently denied. Please enable in browser settings.',
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
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
      final errorStr = error.toString();
      // Handle the common "User denied Geolocation" or "Permission denied" errors on web
      if (errorStr.contains('denied') || errorStr.contains('permission')) {
        return const LocationLookup(
          status: LocationStatus.permissionDenied,
          message: 'Location access was denied. Tap the GPS icon to try again.',
        );
      }
      return LocationLookup(
        status: LocationStatus.error,
        message: 'GPS sync issue: $errorStr',
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
