import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
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
    if (kIsWeb) {
      return _getCurrentLocationWeb();
    }
    return _getCurrentLocationNative();
  }

  /// Direct JS Interop implementation for Web Geolocation.
  /// This is more reliable on browsers than the geolocator package
  /// as it handles permission prompts and timeouts more directly.
  Future<LocationLookup> _getCurrentLocationWeb() async {
    try {
      // Step 1: Attempt High Accuracy
      var position = await _getWebPosition(highAccuracy: true);
      
      // Step 2: Fallback to Low Accuracy if high fails or is unavailable
      position ??= await _getWebPosition(highAccuracy: false);

      if (position != null) {
        return LocationLookup(
          status: LocationStatus.available,
          position: position,
        );
      }

      return const LocationLookup(
        status: LocationStatus.permissionDenied,
        message: 'Location access denied or unavailable. Please check browser settings.',
      );
    } catch (e) {
      return LocationLookup(
        status: LocationStatus.error,
        message: 'Web GPS issue: ${e.toString()}',
      );
    }
  }

  /// Helper to call navigator.geolocation via JS interop
  Future<SavedLocation?> _getWebPosition({required bool highAccuracy}) async {
    final completer = Completer<SavedLocation?>();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final cbOk = 'geoOk_$timestamp';
    final cbErr = 'geoErr_$timestamp';

    // Set up global callbacks for JS to call back into Dart
    globalContext.setProperty(
      cbOk.toJS,
      ((JSNumber lat, JSNumber lng) {
        if (!completer.isCompleted) {
          completer.complete(SavedLocation(
            lat: lat.toDartDouble,
            lng: lng.toDartDouble,
          ));
        }
      }).toJS,
    );

    globalContext.setProperty(
      cbErr.toJS,
      ((JSString err) {
        if (!completer.isCompleted) completer.complete(null);
      }).toJS,
    );

    final accuracy = highAccuracy ? 'true' : 'false';

    try {
      // Use eval for maximum compatibility with browser Geolocation API
      globalContext.callMethod<JSAny?>(
        'eval'.toJS,
        '''(function(){
          if (!navigator.geolocation) {
            window["$cbErr"]("Not supported");
            return;
          }
          navigator.geolocation.getCurrentPosition(
            function(pos) {
              window["$cbOk"](pos.coords.latitude, pos.coords.longitude);
              delete window["$cbOk"];
              delete window["$cbErr"];
            },
            function(err) {
              window["$cbErr"](err.message || "denied");
              delete window["$cbOk"];
              delete window["$cbErr"];
            },
            { enableHighAccuracy: $accuracy, timeout: 8000, maximumAge: 3000 }
          );
        })()'''
            .toJS,
      );
    } catch (e) {
      if (!completer.isCompleted) completer.complete(null);
    }

    // Wait for JS callback or timeout
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
  }

  Future<LocationLookup> _getCurrentLocationNative() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        return const LocationLookup(
          status: LocationStatus.serviceDisabled,
          message: 'Location services disabled.',
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
          message: 'Location permission denied.',
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
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
        message: 'GPS sync issue: $error',
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
