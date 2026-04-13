import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_models.dart';

final notificationServiceProvider = Provider<AppNotificationService>((ref) {
  return AndroidWatchNotificationService();
});

class NotificationSetup {
  const NotificationSetup({
    required this.supported,
    required this.granted,
    required this.label,
    this.needsPermission = false,
  });

  final bool supported;
  final bool granted;
  final String label;
  final bool needsPermission;
}

abstract class AppNotificationService {
  Future<NotificationSetup> initialize();
  Future<NotificationSetup> requestPermission();
  Future<void> showWatchEvent({
    required WatchStopStatus status,
    required WatchEvent event,
  });

  /// Android: high-importance sticky notification (e.g. proximity). No-op elsewhere.
  Future<void> showStickyLocalAlert({
    required String title,
    required String body,
    required int notificationId,
  });
}

class AndroidWatchNotificationService implements AppNotificationService {
  static const MethodChannel _channel = MethodChannel(
    'barbados_bus/notifications',
  );

  NotificationSetup _lastSetup = const NotificationSetup(
    supported: false,
    granted: false,
    label: 'In-app sound + banner',
  );

  bool get _androidSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<NotificationSetup> initialize() {
    return _invokeSetup('initialize');
  }

  @override
  Future<NotificationSetup> requestPermission() {
    return _invokeSetup('requestPermission');
  }

  Future<NotificationSetup> _invokeSetup(String method) async {
    if (!_androidSupported) {
      _lastSetup = const NotificationSetup(
        supported: false,
        granted: false,
        label: 'In-app sound + banner',
      );
      return _lastSetup;
    }

    try {
      final result =
          await _channel.invokeMapMethod<Object?, Object?>(method) ??
          const <Object?, Object?>{};
      final granted = result['granted'] == true;
      final supported = result['supported'] != false;
      _lastSetup = NotificationSetup(
        supported: supported,
        granted: granted,
        needsPermission: result['needsPermission'] == true,
        label:
            result['label']?.toString() ??
            (granted ? 'Phone alerts ready' : 'Phone alerts blocked'),
      );
      return _lastSetup;
    } catch (_) {
      _lastSetup = const NotificationSetup(
        supported: false,
        granted: false,
        label: 'In-app sound + banner',
      );
      return _lastSetup;
    }
  }

  String _titleForEvent(WatchStopStatus status, WatchEvent event) {
    final routeParts = [
      event.routeNumber,
      event.routeName,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).toList();
    final routeLabel = routeParts.isEmpty ? 'Bus alert' : routeParts.join(' ');
    final stopLabel = event.stopName ?? status.stop.name;

    switch (event.kind) {
      case 'alert_eta_30m':
        return '$routeLabel in 30 min';
      case 'alert_eta_10m':
        return '$routeLabel in 10 min';
      case 'alert_eta_5m':
        return '$routeLabel in 5 min';
      case 'alert_near_stop':
        return '$routeLabel close to $stopLabel';
      case 'upstream_pass':
        return '$routeLabel approaching $stopLabel';
      case 'observed_pass':
      case 'observed_arrival':
        return '$routeLabel passed $stopLabel';
      default:
        return '$routeLabel toward $stopLabel';
    }
  }

  @override
  Future<void> showWatchEvent({
    required WatchStopStatus status,
    required WatchEvent event,
  }) async {
    final setup = _lastSetup.granted ? _lastSetup : await initialize();
    if (!setup.granted || !_androidSupported) {
      return;
    }

    final sticky = event.kind == 'alert_near_stop' ||
        event.kind == 'observed_pass' ||
        event.kind == 'observed_arrival' ||
        event.kind == 'upstream_pass';

    try {
      await _channel.invokeMethod<void>('showEvent', {
        'id': event.id.hashCode & 0x7fffffff,
        'title': _titleForEvent(status, event),
        'body': event.message,
        'kind': event.kind,
        'sticky': sticky,
      });
    } catch (_) {
      // Keep in-app snackbar as fallback when native notification path is unavailable.
    }
  }

  @override
  Future<void> showStickyLocalAlert({
    required String title,
    required String body,
    required int notificationId,
  }) async {
    final setup = _lastSetup.granted ? _lastSetup : await initialize();
    if (!setup.granted || !_androidSupported) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('showEvent', {
        'id': notificationId & 0x7fffffff,
        'title': title,
        'body': body,
        'kind': 'proximity_radius',
        'sticky': true,
      });
    } catch (_) {}
  }
}
