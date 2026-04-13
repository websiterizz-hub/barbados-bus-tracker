import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_models.dart';

final storageProvider = FutureProvider<AppStorage>((ref) async {
  final preferences = await SharedPreferences.getInstance();
  return AppStorage(preferences);
});

class AppStorage {
  AppStorage(this._preferences);

  final SharedPreferences _preferences;

  static const _recentStopsKey = 'recent_stops';
  static const _lastLocationKey = 'last_location';
  static const _watchedStopsKey = 'watched_stops';
  static const _alertMinutesKey = 'alert_minutes';

  List<int> loadRecentStopIds() {
    return _preferences
            .getStringList(_recentStopsKey)
            ?.map(int.parse)
            .toList() ??
        [];
  }

  Future<void> saveRecentStop(int stopId) async {
    final existing = loadRecentStopIds();
    existing.remove(stopId);
    existing.insert(0, stopId);
    await _preferences.setStringList(
      _recentStopsKey,
      existing.take(6).map((value) => value.toString()).toList(),
    );
  }

  List<int> loadWatchedStopIds() {
    return _preferences
            .getStringList(_watchedStopsKey)
            ?.map(int.parse)
            .toList() ??
        [];
  }

  Future<void> saveWatchedStops(List<int> stopIds) async {
    await _preferences.setStringList(
      _watchedStopsKey,
      stopIds.map((value) => value.toString()).toList(),
    );
  }

  List<int> loadAlertMinutes() {
    final saved = _preferences
        .getStringList(_alertMinutesKey)
        ?.map(int.parse)
        .toList();
    if (saved == null || saved.isEmpty) {
      return const [30, 10, 5];
    }
    return saved;
  }

  Future<void> saveAlertMinutes(Iterable<int> minutes) async {
    final normalized = minutes.toSet().toList()
      ..sort((left, right) => right.compareTo(left));
    await _preferences.setStringList(
      _alertMinutesKey,
      normalized.map((value) => value.toString()).toList(),
    );
  }

  SavedLocation? loadLastLocation() {
    final raw = _preferences.getString(_lastLocationKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return SavedLocation.fromJson(decoded);
  }

  Future<void> saveLastLocation(SavedLocation location) async {
    await _preferences.setString(
      _lastLocationKey,
      jsonEncode(location.toJson()),
    );
  }
}
