import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/app_widgets.dart';
import '../../core/time_format.dart';
import '../../core/storage.dart';
import '../../models/app_models.dart';
import '../../services/api_client.dart';
import '../../services/location_service.dart';
import '../../services/notification_service.dart';

const _defaultIslandCenter = LatLng(13.0975, -59.6130);
const _legacyWatchStopKeywords = <String>['foul bay', 'oxnards'];
const _autoWatchStopCount = 4;
const _nearbyStopFetchLimit = 12;
const _fastRefreshSeconds = 2;
const _comingSoonWindowSeconds = 30 * 60;
final _distanceCalculator = const Distance();

enum _SurfaceStatusFilter { all, tracking, atTerminal, announced }

String _surfaceStatusFilterLabel(_SurfaceStatusFilter filter) {
  switch (filter) {
    case _SurfaceStatusFilter.all:
      return 'All';
    case _SurfaceStatusFilter.tracking:
      return 'Tracking';
    case _SurfaceStatusFilter.atTerminal:
      return 'At terminal';
    case _SurfaceStatusFilter.announced:
      return 'Announced';
  }
}

String _emptyNearbyMapMessage(_SurfaceStatusFilter filter) {
  switch (filter) {
    case _SurfaceStatusFilter.all:
      return 'No buses on your map right now.';
    case _SurfaceStatusFilter.tracking:
      return 'No live-tracking buses on your map right now.';
    case _SurfaceStatusFilter.atTerminal:
      return 'No buses at terminal on your map right now.';
    case _SurfaceStatusFilter.announced:
      return 'No announced buses on your map right now.';
  }
}

bool _matchesStatusFilter(String state, _SurfaceStatusFilter filter) {
  switch (filter) {
    case _SurfaceStatusFilter.all:
      return true;
    case _SurfaceStatusFilter.tracking:
      return state == 'tracking';
    case _SurfaceStatusFilter.atTerminal:
      return state == 'at_terminal';
    case _SurfaceStatusFilter.announced:
      return state == 'announced';
  }
}

String _routePath(String routeId, {int? vehicleUid}) {
  if (vehicleUid == null) {
    return '/routes/$routeId';
  }
  return '/routes/$routeId?vehicle=$vehicleUid';
}

int _elapsedSinceReference(DateTime now, DateTime? referenceTime) {
  if (referenceTime == null) {
    return 0;
  }
  final seconds = now.difference(referenceTime).inSeconds;
  return seconds < 0 ? 0 : seconds;
}

String _preciseCountdownLabel(int seconds) {
  return formatDurationHms(seconds);
}

String _liveEtaCountdown({
  required int etaSeconds,
  required DateTime now,
  required DateTime? referenceTime,
}) {
  final elapsed = _elapsedSinceReference(now, referenceTime);
  return _preciseCountdownLabel(etaSeconds - elapsed);
}

int? _liveSeenSeconds({
  required int? baseSeconds,
  required DateTime now,
  required DateTime? referenceTime,
}) {
  if (baseSeconds == null) {
    return null;
  }
  return baseSeconds + _elapsedSinceReference(now, referenceTime);
}

/// Whether a tracked bus is likely moving toward the user, away (passed), or unclear.
enum _BusUserRelative { unknown, approaching, passed }

double _normalizeBearingDelta(double radians) {
  var x = radians;
  while (x <= -math.pi) {
    x += 2 * math.pi;
  }
  while (x > math.pi) {
    x -= 2 * math.pi;
  }
  return x;
}

/// Initial bearing from (fromLat,fromLng) toward (toLat,toLng), radians clockwise from north.
double _initialBearingRad(
  double fromLat,
  double fromLng,
  double toLat,
  double toLng,
) {
  final phi1 = fromLat * math.pi / 180.0;
  final phi2 = toLat * math.pi / 180.0;
  final dL = (toLng - fromLng) * math.pi / 180.0;
  final y = math.sin(dL) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dL);
  return math.atan2(y, x);
}

double? _headingFieldToRadians(double? h) {
  if (h == null || !h.isFinite) {
    return null;
  }
  // Locator may send radians (small magnitude) or degrees (0â€“360).
  if (h.abs() < 6.5) {
    return h;
  }
  return h * math.pi / 180.0;
}

/// Local tangent plane: east/north meters from [from] to [to] (small distances).
(double, double) _enuDeltaMeters(
  double fromLat,
  double fromLng,
  double toLat,
  double toLng,
) {
  const mPerDegLat = 111320.0;
  final cosLat = math.cos(fromLat * math.pi / 180.0);
  final mPerDegLng = 111320.0 * cosLat;
  final north = (toLat - fromLat) * mPerDegLat;
  final east = (toLng - fromLng) * mPerDegLng;
  return (east, north);
}

/// Uses actual motion (prevâ†’now) vs busâ†’you. Telemetry heading is often wrong; motion wins.
_BusUserRelative _busRelativeToUser(Vehicle vehicle, SavedLocation? user) {
  if (user == null) {
    return _BusUserRelative.unknown;
  }
  if (vehicle.confidenceState != 'tracking') {
    return _BusUserRelative.unknown;
  }
  if (!vehicle.moving) {
    return _BusUserRelative.unknown;
  }
  final d = _effectiveDistanceUserToVehicle(vehicle, user);
  if (d == null || d > 4000) {
    return _BusUserRelative.unknown;
  }

  final prev = vehicle.previousPosition;
  if (prev != null) {
    final move = _enuDeltaMeters(
      prev.lat,
      prev.lng,
      vehicle.position.lat,
      vehicle.position.lng,
    );
    final moveLen = math.sqrt(move.$1 * move.$1 + move.$2 * move.$2);
    if (moveLen >= 5.5) {
      final toUser = _enuDeltaMeters(
        vehicle.position.lat,
        vehicle.position.lng,
        user.lat,
        user.lng,
      );
      final toLen = math.sqrt(toUser.$1 * toUser.$1 + toUser.$2 * toUser.$2);
      if (toLen >= 4) {
        final cosAlign =
            (move.$1 * toUser.$1 + move.$2 * toUser.$2) / (moveLen * toLen);
        if (cosAlign < -0.06) {
          return _BusUserRelative.passed;
        }
        if (cosAlign > 0.09) {
          return _BusUserRelative.approaching;
        }
        return _BusUserRelative.unknown;
      }
    }

    if (moveLen >= 4) {
      final courseFromMotion = math.atan2(move.$1, move.$2);
      final toUserBearing = _initialBearingRad(
        vehicle.position.lat,
        vehicle.position.lng,
        user.lat,
        user.lng,
      );
      final diff = _normalizeBearingDelta(toUserBearing - courseFromMotion);
      final c = math.cos(diff);
      if (c < -0.12) {
        return _BusUserRelative.passed;
      }
      if (c > 0.14) {
        return _BusUserRelative.approaching;
      }
    }
  }

  final headingRad = _headingFieldToRadians(vehicle.position.heading);
  if (headingRad != null) {
    final toUserBearing = _initialBearingRad(
      vehicle.position.lat,
      vehicle.position.lng,
      user.lat,
      user.lng,
    );
    final diff = _normalizeBearingDelta(toUserBearing - headingRad);
    final c = math.cos(diff);
    if (c < -0.2) {
      return _BusUserRelative.passed;
    }
    if (c > 0.22) {
      return _BusUserRelative.approaching;
    }
  }

  return _BusUserRelative.unknown;
}

int? _estimateSecondsToReachUser({
  required int distanceMeters,
  required double? speedKph,
  required _BusUserRelative rel,
}) {
  if (rel != _BusUserRelative.approaching) {
    return null;
  }
  final kph = speedKph != null && speedKph >= 4
      ? math.min(55.0, speedKph)
      : (speedKph != null && speedKph > 0
          ? math.max(speedKph, 14.0)
          : 16.0);
  final hours = (distanceMeters / 1000.0) / kph;
  final sec = (hours * 3600).round();
  return sec.clamp(25, 7200);
}

/// Crow-flight meters user â†’ bus (tracked API vehicles often omit `distance_m`).
int? _userToVehicleMeters(SavedLocation? user, Vehicle vehicle) {
  if (user == null) {
    return null;
  }
  final lat = vehicle.position.lat;
  final lng = vehicle.position.lng;
  if (!lat.isFinite ||
      !lng.isFinite ||
      (lat.abs() < 1e-5 && lng.abs() < 1e-5)) {
    return null;
  }
  return _distanceCalculator
      .as(
        LengthUnit.Meter,
        LatLng(user.lat, user.lng),
        LatLng(lat, lng),
      )
      .round();
}

int? _effectiveDistanceUserToVehicle(Vehicle vehicle, SavedLocation? user) {
  return vehicle.distanceMeters ?? _userToVehicleMeters(user, vehicle);
}

int _proximityAlertRadiusMeters(int scanRadiusMeters) {
  return (scanRadiusMeters * 0.45).round().clamp(200, 650);
}

DateTime? _tryParseIso(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw);
}

int? _eventAgeSeconds(String? raw, DateTime now) {
  final parsed = _tryParseIso(raw);
  if (parsed == null) {
    return null;
  }
  final seconds = now.difference(parsed.toLocal()).inSeconds;
  return seconds < 0 ? 0 : seconds;
}

// ignore: unused_element
String _watchTierLabel(Arrival arrival) {
  if (arrival.confidenceState != 'tracking') {
    return arrival.statusText;
  }
  final etaSeconds = arrival.watchEtaSeconds ?? arrival.etaSeconds;
  if (etaSeconds <= 300) {
    return '5-min watch';
  }
  if (etaSeconds <= 600) {
    return '10-min watch';
  }
  if (etaSeconds <= _comingSoonWindowSeconds) {
    return '30-min watch';
  }
  return 'Live watch';
}

String _explicitArrivalStatusLine(
  Arrival arrival,
  DateTime now,
  DateTime? referenceTime,
) {
  final seenSeconds = _liveSeenSeconds(
    baseSeconds: arrival.lastSeenSeconds,
    now: now,
    referenceTime: referenceTime,
  );
  switch (arrival.confidenceState) {
    case 'tracking':
      return 'ETA to stop ${_liveEtaCountdown(etaSeconds: arrival.watchEtaSeconds ?? arrival.etaSeconds, now: now, referenceTime: referenceTime)}${seenSeconds == null ? '' : ' | ping ${seenSeconds}s ago'}';
    case 'at_terminal':
      return 'At terminal | scheduled ${arrival.scheduledLabel}';
    case 'stale':
      return 'Signal lost${seenSeconds == null ? '' : ' | last ping ${seenSeconds}s ago'}';
    default:
      return 'Scheduled after ${arrival.scheduledLabel}';
  }
}

Vehicle? _leadVehicleForAreaRoute(
  _AreaRouteMatch item,
  Map<String, TrackedRoute> trackedByRouteId,
) {
  if (item.vehicle != null) {
    return item.vehicle;
  }
  final trackedRoute = trackedByRouteId[item.arrival.routeId];
  if (trackedRoute == null || trackedRoute.activeVehicles.isEmpty) {
    return null;
  }
  return trackedRoute.activeVehicles.first;
}

String _effectiveAreaRouteState(
  _AreaRouteMatch item,
  Map<String, TrackedRoute> trackedByRouteId,
) {
  return _leadVehicleForAreaRoute(item, trackedByRouteId)?.confidenceState ??
      item.arrival.confidenceState;
}

String _effectiveAreaRouteLabel(
  _AreaRouteMatch item,
  Map<String, TrackedRoute> trackedByRouteId,
) {
  return _leadVehicleForAreaRoute(item, trackedByRouteId)?.statusText ??
      item.arrival.statusText;
}

String _watchVehicleMetaLine(
  Vehicle vehicle,
  DateTime now,
  DateTime? referenceTime,
) {
  final distanceText = vehicle.distanceMeters == null
      ? 'Near stop'
      : '${vehicle.distanceMeters}m from stop';
  final motionText = vehicle.moving ? 'moving now' : vehicle.statusText;
  final seenSeconds = _liveSeenSeconds(
    baseSeconds: vehicle.lastSeenSeconds,
    now: now,
    referenceTime: referenceTime,
  );
  return '$distanceText | $motionText${seenSeconds == null ? '' : ' | ping ${seenSeconds}s ago'}';
}

String _passBadgeLabel(WatchEvent event, DateTime now) {
  final ageSeconds = _eventAgeSeconds(event.happenedAt, now);
  if (ageSeconds == null) {
    return 'Passed this stop';
  }
  if (ageSeconds < 60) {
    return 'Passed just now';
  }
  if (ageSeconds < 3600) {
    return 'Passed ${ageSeconds ~/ 60}m ago';
  }
  return 'Passed earlier';
}

int _watchEventPriority(String kind) {
  switch (kind) {
    case 'observed_pass':
    case 'observed_arrival':
      return 0;
    case 'alert_near_stop':
      return 1;
    case 'upstream_pass':
      return 2;
    case 'alert_eta_5m':
      return 3;
    case 'alert_eta_10m':
      return 4;
    case 'alert_eta_30m':
      return 5;
    case 'prediction_evaluated':
      return 6;
    default:
      return 9;
  }
}

IconData _watchEventIcon(String kind) {
  switch (kind) {
    case 'upstream_pass':
      return Icons.alt_route_rounded;
    case 'alert_eta_30m':
    case 'alert_eta_10m':
    case 'alert_eta_5m':
      return Icons.notifications_active_rounded;
    case 'alert_near_stop':
      return Icons.campaign_rounded;
    case 'observed_pass':
    case 'observed_arrival':
    case 'prediction_evaluated':
      return Icons.history_rounded;
    default:
      return Icons.analytics_rounded;
  }
}

Color _watchEventColor(String kind) {
  switch (kind) {
    case 'observed_pass':
    case 'observed_arrival':
    case 'prediction_evaluated':
      return const Color(0xFF9B4D3D);
    case 'alert_near_stop':
      return const Color(0xFF0B7A75);
    default:
      return const Color(0xFF355C7D);
  }
}

String _watchEventDirectionLine(WatchEvent event) {
  final direction = event.routeDirection;
  final destination = event.destinationName;
  if (destination != null && destination.trim().isNotEmpty) {
    return 'Toward $destination';
  }
  if (direction == null || direction.trim().isEmpty) {
    return event.routeName ?? 'Tracked route';
  }

  final lower = direction.toLowerCase();
  if (lower.contains(' towards ')) {
    return 'Toward ${direction.split(RegExp(r'\s+towards\s+', caseSensitive: false)).last}';
  }
  if (direction.contains('->')) {
    return 'Toward ${direction.split('->').last.trim()}';
  }
  if (lower.contains(' to ')) {
    return 'Toward ${direction.split(RegExp(r'\s+to\s+', caseSensitive: false)).last}';
  }
  return direction;
}

String _eventDirectionLine(WatchEvent event) => _watchEventDirectionLine(event);

String _formatDistanceLabel(int meters) {
  if (meters >= 10000) {
    return '${(meters / 1000).round()} km';
  }
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }
  return '$meters m';
}

final _routeFocuses = <_FocusQuery>[
  _FocusQuery(
    label: 'Bridgetown',
    keywords: ['bridgetown', 'fairchild', 'princess alice'],
  ),
  _FocusQuery(label: 'Warrens', keyword: 'warrens'),
  _FocusQuery(label: "Sam Lord's", keyword: 'sam lord'),
  _FocusQuery(label: 'College Savannah', keyword: 'college savannah'),
  _FocusQuery(label: 'Oistins', keyword: 'oistins'),
  _FocusQuery(label: 'Six Roads', keyword: 'six roads'),
];

final _stopFocuses = <_FocusQuery>[
  _FocusQuery(
    label: 'Bridgetown',
    keywords: ['bridgetown', 'princess alice', 'fairchild'],
  ),
  _FocusQuery(label: 'Warrens', keyword: 'warrens'),
  _FocusQuery(label: 'Six Roads', keyword: 'six roads'),
  _FocusQuery(label: 'College Savannah', keyword: 'college savannah'),
  _FocusQuery(label: 'Oistins', keyword: 'oistins'),
  _FocusQuery(label: 'Foul Bay', keyword: 'foul bay'),
];

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  Timer? _refreshTimer;
  Timer? _uiTicker;
  bool _isLoading = true;
  String? _message;
  NearbyResponse? _nearby;
  TrackedRoutesResponse? _trackedRoutes;
  List<WatchStopStatus> _watchStatuses = const [];
  SavedLocation? _lastKnownLocation;
  SavedLocation? _activeLocation;
  List<int> _recentStopIds = const [];
  List<int> _savedWatchedStopIds = const [];
  int _radiusMeters = 800;
  LocationStatus? _locationStatus;
  final Set<String> _seenWatchEventIds = <String>{};
  bool _watchNotificationsPrimed = false;
  Set<int> _enabledReminderMinutes = {30, 10, 5};
  DateTime _uiNow = DateTime.now();
  DateTime? _lastRefreshAt;
  NotificationSetup _notificationSetup = const NotificationSetup(
    supported: false,
    granted: false,
    label: 'In-app sound + banner',
  );
  DateTime? _lastProximityAlertAt;

  @override
  void initState() {
    super.initState();
    _startUiTicker();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _uiTicker?.cancel();
    super.dispose();
  }

  void _startUiTicker() {
    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _uiNow = DateTime.now();
      });
    });
  }

  Future<void> _initialize() async {
    final bootstrap = await ref.read(bootstrapProvider.future);
    _radiusMeters = bootstrap.defaultNearbyRadiusMeters;
    final storage = await ref.read(storageProvider.future);
    final notificationSetup = await ref
        .read(notificationServiceProvider)
        .initialize();
    _lastKnownLocation = storage.loadLastLocation();
    _recentStopIds = storage.loadRecentStopIds();
    _enabledReminderMinutes = storage.loadAlertMinutes().toSet();
    final watchedStopIds = storage.loadWatchedStopIds();
    final legacyWatchStopIds = _resolveLegacyWatchStopIds(bootstrap);
    _savedWatchedStopIds = watchedStopIds
        .where((stopId) => !legacyWatchStopIds.contains(stopId))
        .toList();
    if (!_listsEqual(watchedStopIds, _savedWatchedStopIds)) {
      await storage.saveWatchedStops(_savedWatchedStopIds);
    }
    if (mounted) {
      setState(() {
        _notificationSetup = notificationSetup;
      });
    }
    await _refresh();
  }

  void _scheduleRefresh(int seconds) {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(
      Duration(seconds: seconds.clamp(2, 12)),
      () => unawaited(_refresh(silent: true)),
    );
  }

  Future<void> _refresh({
    bool silent = false,
    bool forceRadiusExpansion = false,
  }) async {
    if (!silent && mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    final api = ref.read(apiClientProvider);
    final locationService = ref.read(locationServiceProvider);
    final storage = await ref.read(storageProvider.future);
    final lookup = await locationService.getCurrentLocation();

    SavedLocation? targetLocation = lookup.position ?? _lastKnownLocation;
    String? message;

    if (lookup.status == LocationStatus.available && lookup.position != null) {
      _lastKnownLocation = lookup.position;
      await storage.saveLastLocation(lookup.position!);
    } else if (_lastKnownLocation != null) {
      message = 'Using last saved area because live location is unavailable.';
    } else {
      message = lookup.message ?? 'Unable to get your location right now.';
    }

    final radiusMeters = forceRadiusExpansion ? 1500 : _radiusMeters;
    NearbyResponse? nearby;
    TrackedRoutesResponse? trackedRoutes;
    List<WatchStopStatus> watchStatuses = const [];
    var activeWatchStopIds = List<int>.from(_savedWatchedStopIds);

    try {
      trackedRoutes = await api.getTrackedRoutes();
    } catch (error) {
      message = error.toString();
    }

    if (targetLocation != null) {
      try {
        nearby = await api.getNearbyStops(
          lat: targetLocation.lat,
          lng: targetLocation.lng,
          radiusMeters: radiusMeters,
          limit: _nearbyStopFetchLimit,
        );

        for (final stopId in _deriveAutoWatchStopIds(nearby)) {
          if (!activeWatchStopIds.contains(stopId)) {
            activeWatchStopIds.add(stopId);
          }
        }

        if (nearby.nearbyStops.isEmpty && radiusMeters < 1500) {
          message ??=
              'No nearby stops with strong evidence yet. Try widening radius.';
        }
      } catch (error) {
        message = error.toString();
      }
    }

    if (activeWatchStopIds.isNotEmpty) {
      try {
        watchStatuses = await Future.wait(
          activeWatchStopIds.map(api.getWatchStopStatus),
        );
      } catch (error) {
        message ??= error.toString();
      }
    }

    var refreshHintSeconds = [
      nearby?.refreshHintSeconds,
      trackedRoutes?.refreshHintSeconds,
      ...watchStatuses.map((status) => status.refreshHintSeconds),
    ].whereType<int>().fold<int>(30, (best, next) => next < best ? next : best);
    if (targetLocation != null) {
      refreshHintSeconds = math.min(refreshHintSeconds, _fastRefreshSeconds);
    }
    _scheduleRefresh(refreshHintSeconds);
    final completedAt = DateTime.now();
    final proximityPings = _computeProximityPings(
      user: targetLocation,
      nearby: nearby,
      tracked: trackedRoutes,
      scanRadiusMeters: radiusMeters,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _radiusMeters = radiusMeters;
      _nearby = nearby;
      _trackedRoutes = trackedRoutes;
      _watchStatuses = watchStatuses;
      _activeLocation = targetLocation;
      _message = message;
      _locationStatus = lookup.status;
      _isLoading = false;
      _lastRefreshAt = completedAt;
      _uiNow = completedAt;
    });

    _handleWatchNotifications(watchStatuses);
    _handleProximityUi(proximityPings);
  }

  List<_ProximityPing> _computeProximityPings({
    required SavedLocation? user,
    required NearbyResponse? nearby,
    required TrackedRoutesResponse? tracked,
    required int scanRadiusMeters,
  }) {
    if (user == null) {
      return const [];
    }
    final alertR = _proximityAlertRadiusMeters(scanRadiusMeters);
    final seen = <int>{};
    final out = <_ProximityPing>[];

    void consider(Vehicle v) {
      if (!seen.add(v.uid)) {
        return;
      }
      if (v.confidenceState != 'tracking' &&
          v.confidenceState != 'at_terminal') {
        return;
      }
      final d = _userToVehicleMeters(user, v);
      if (d == null || d > alertR) {
        return;
      }
      out.add(
        _ProximityPing(
          uid: v.uid,
          routeLabel:
              v.routeNumber.isEmpty ? 'Bus ${v.uid}' : v.routeNumber,
          distanceMeters: d,
        ),
      );
    }

    if (nearby != null) {
      for (final v in nearby.nearbyVehicles) {
        consider(v);
      }
    }
    if (tracked != null) {
      for (final r in tracked.routes) {
        for (final v in r.activeVehicles) {
          consider(v);
        }
      }
    }

    out.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return out;
  }

  void _handleProximityUi(List<_ProximityPing> pings) {
    if (!mounted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) {
        return;
      }
      messenger.clearMaterialBanners();
      if (pings.isEmpty) {
        return;
      }
      final alertR = _proximityAlertRadiusMeters(_radiusMeters);
      final summary = pings
          .take(5)
          .map((p) => '${p.routeLabel} Â· ${p.distanceMeters} m')
          .join('   ');
      messenger.showMaterialBanner(
        MaterialBanner(
          backgroundColor: const Color(0xFFFFF3E0),
          content: Text(
            'Bus inside ~${alertR}m of you: $summary',
            style: const TextStyle(color: Color(0xFF132221)),
          ),
          leading: const Icon(
            Icons.notifications_active,
            color: Color(0xFF9B2E2E),
          ),
          actions: [
            TextButton(
              onPressed: () => messenger.hideCurrentMaterialBanner(),
              child: const Text('DISMISS'),
            ),
          ],
        ),
      );
    });

    if (pings.isEmpty) {
      return;
    }
    final now = DateTime.now();
    if (_lastProximityAlertAt != null &&
        now.difference(_lastProximityAlertAt!) <
            const Duration(seconds: 28)) {
      return;
    }
    _lastProximityAlertAt = now;
    unawaited(SystemSound.play(SystemSoundType.alert));
    final alertR = _proximityAlertRadiusMeters(_radiusMeters);
    final lines = pings
        .take(4)
        .map((x) => '${x.routeLabel} ${x.distanceMeters} m')
        .join(' Â· ');
    unawaited(
      ref.read(notificationServiceProvider).showStickyLocalAlert(
        title: 'Bus inside ~${alertR}m radius',
        body: lines,
        notificationId: 9_010_001,
      ),
    );
  }

  Future<void> _fixLocationAccess() async {
    final locationService = ref.read(locationServiceProvider);
    if (_locationStatus == LocationStatus.serviceDisabled) {
      await locationService.openLocationSettings();
    } else {
      await locationService.openAppSettings();
    }
  }

  Future<void> _enablePhoneAlerts() async {
    final setup = await ref
        .read(notificationServiceProvider)
        .requestPermission();
    if (!mounted) {
      return;
    }

    setState(() {
      _notificationSetup = setup;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(setup.label),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _toggleReminderMinute(int minute) async {
    final updated = Set<int>.from(_enabledReminderMinutes);
    if (updated.contains(minute)) {
      updated.remove(minute);
    } else {
      updated.add(minute);
    }

    if (updated.isEmpty) {
      updated.add(minute);
    }

    final storage = await ref.read(storageProvider.future);
    await storage.saveAlertMinutes(updated);
    if (!mounted) {
      return;
    }

    setState(() {
      _enabledReminderMinutes = updated;
    });
  }

  List<int> _resolveLegacyWatchStopIds(AppBootstrap bootstrap) {
    final ids = <int>[];
    for (final keyword in _legacyWatchStopKeywords) {
      for (final stop in bootstrap.stops) {
        final haystack = '${stop.name} ${stop.description}'.toLowerCase();
        if (haystack.contains(keyword) && !ids.contains(stop.id)) {
          ids.add(stop.id);
          break;
        }
      }
    }
    return ids;
  }

  List<int> _deriveAutoWatchStopIds(NearbyResponse nearby) {
    final rankedStops =
        nearby.nearbyStops
            .where(
              (stop) => stop.arrivals.isNotEmpty || stop.stop.routes.isNotEmpty,
            )
            .toList()
          ..sort((left, right) {
            final leftState = left.primaryArrivals.isNotEmpty
                ? 0
                : left.announcedArrivals.isNotEmpty
                ? 1
                : 2;
            final rightState = right.primaryArrivals.isNotEmpty
                ? 0
                : right.announcedArrivals.isNotEmpty
                ? 1
                : 2;
            if (leftState != rightState) {
              return leftState.compareTo(rightState);
            }

            final leftArrivalCount = left.arrivals.length;
            final rightArrivalCount = right.arrivals.length;
            if (leftArrivalCount != rightArrivalCount) {
              return rightArrivalCount.compareTo(leftArrivalCount);
            }

            return left.distanceMeters.compareTo(right.distanceMeters);
          });

    return rankedStops
        .map((stop) => stop.stop.id)
        .take(_autoWatchStopCount)
        .toList();
  }

  bool _listsEqual(List<int> left, List<int> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  int? _reminderMinuteForEvent(WatchEvent event) {
    switch (event.kind) {
      case 'alert_eta_30m':
        return 30;
      case 'alert_eta_10m':
        return 10;
      case 'alert_eta_5m':
        return 5;
      default:
        return null;
    }
  }

  bool _shouldNotifyForEvent(WatchEvent event) {
    final minute = _reminderMinuteForEvent(event);
    if (minute == null) {
      return true;
    }
    return _enabledReminderMinutes.contains(minute);
  }

  Future<void> _playAlertCue(WatchEvent event) async {
    final kind = event.kind;
    final sound =
        kind == 'observed_pass' ||
            kind == 'observed_arrival' ||
            kind == 'alert_near_stop' ||
            kind == 'upstream_pass'
        ? SystemSoundType.alert
        : SystemSoundType.click;
    await SystemSound.play(sound);
  }

  void _handleWatchNotifications(List<WatchStopStatus> statuses) {
    if (!mounted || statuses.isEmpty) {
      return;
    }

    final allNotifiable = <({WatchStopStatus status, WatchEvent event})>[];
    for (final status in statuses) {
      for (final event in status.recentEvents) {
        if (event.kind == 'upstream_pass' ||
            event.kind == 'alert_eta_30m' ||
            event.kind == 'alert_eta_10m' ||
            event.kind == 'alert_eta_5m' ||
            event.kind == 'alert_near_stop' ||
            event.kind == 'observed_pass' ||
            event.kind == 'observed_arrival') {
          allNotifiable.add((status: status, event: event));
        }
      }
    }

    if (!_watchNotificationsPrimed) {
      _seenWatchEventIds.addAll(allNotifiable.map((item) => item.event.id));
      _watchNotificationsPrimed = true;
      return;
    }

    final allUnseen = allNotifiable
        .where((item) => !_seenWatchEventIds.contains(item.event.id))
        .toList();
    if (allUnseen.isEmpty) {
      return;
    }

    _seenWatchEventIds.addAll(allUnseen.map((item) => item.event.id));
    final unseen = allUnseen
        .where((item) => _shouldNotifyForEvent(item.event))
        .toList();
    if (unseen.isEmpty) {
      return;
    }

    unseen.sort((left, right) {
      final priorityOrder = <String, int>{
        'observed_pass': 0,
        'observed_arrival': 0,
        'upstream_pass': 1,
        'alert_near_stop': 2,
        'alert_eta_5m': 3,
        'alert_eta_10m': 4,
        'alert_eta_30m': 5,
      };
      final leftPriority = priorityOrder[left.event.kind] ?? 9;
      final rightPriority = priorityOrder[right.event.kind] ?? 9;
      if (leftPriority != rightPriority) {
        return leftPriority.compareTo(rightPriority);
      }
      return (right.event.happenedAt ?? '').compareTo(
        left.event.happenedAt ?? '',
      );
    });

    final notificationService = ref.read(notificationServiceProvider);
    for (final item in unseen.take(5)) {
      unawaited(
        notificationService.showWatchEvent(
          status: item.status,
          event: item.event,
        ),
      );
    }
    unawaited(_playAlertCue(unseen.first.event));

    final first = unseen.first.event;
    final stickySnack = first.kind == 'alert_near_stop' ||
        first.kind == 'observed_pass' ||
        first.kind == 'observed_arrival' ||
        first.kind == 'upstream_pass';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(first.message),
        behavior: SnackBarBehavior.floating,
        duration: stickySnack
            ? const Duration(minutes: 2)
            : const Duration(seconds: 6),
        showCloseIcon: true,
      ),
    );
  }

  List<StopSummary> _recentStops(AppBootstrap bootstrap) {
    final stopById = {for (final stop in bootstrap.stops) stop.id: stop};

    return _recentStopIds
        .map((stopId) => stopById[stopId])
        .whereType<StopSummary>()
        .toList();
  }

  Iterable<NearbyStop> _stopsWithPrimary() {
    return _nearby?.nearbyStops.where(
          (stop) => stop.primaryArrivals.isNotEmpty,
        ) ??
        const Iterable.empty();
  }

  Iterable<NearbyStop> _stopsWithAnnounced() {
    return _nearby?.nearbyStops.where(
          (stop) => stop.announcedArrivals.isNotEmpty,
        ) ??
        const Iterable.empty();
  }

  List<_AreaRouteMatch> _areaRouteMatches() {
    final nearby = _nearby;
    if (nearby == null) {
      return const [];
    }

    final byKey = <String, _AreaRouteMatch>{};
    final vehicles = nearby.nearbyVehicles;

    for (final stop in nearby.nearbyStops) {
      for (final arrival in stop.arrivals) {
        final key =
            '${arrival.routeId}|${arrival.direction.toLowerCase()}|${arrival.routeNumber}';
        final matchingVehicle = vehicles
            .where((vehicle) {
              if (arrival.vehicleUid != null &&
                  vehicle.uid == arrival.vehicleUid) {
                return true;
              }
              return arrival.liveRouteId != null &&
                  vehicle.routeId == arrival.liveRouteId &&
                  vehicle.routeNumber == arrival.routeNumber;
            })
            .cast<Vehicle?>()
            .firstWhere((vehicle) => vehicle != null, orElse: () => null);

        final candidate = _AreaRouteMatch(
          stop: stop.stop,
          stopDistanceMeters: stop.distanceMeters,
          arrival: arrival,
          vehicle: matchingVehicle,
        );
        final current = byKey[key];
        if (current == null ||
            _compareAreaRouteMatches(candidate, current) < 0) {
          byKey[key] = candidate;
        }
      }
    }

    final results = byKey.values.toList()..sort(_compareAreaRouteMatches);
    return results;
  }

  List<_TrackedAreaVehicle> _trackedAreaVehicles() {
    final nearby = _nearby;
    final trackedRoutes = _trackedRoutes;
    if (nearby == null || trackedRoutes == null) {
      return const [];
    }

    final bestStopByRouteId = <String, NearbyStop>{};
    for (final stop in nearby.nearbyStops) {
      for (final route in stop.stop.routes) {
        final current = bestStopByRouteId[route.id];
        if (current == null || stop.distanceMeters < current.distanceMeters) {
          bestStopByRouteId[route.id] = stop;
        }
      }
      for (final arrival in stop.arrivals) {
        final current = bestStopByRouteId[arrival.routeId];
        if (current == null || stop.distanceMeters < current.distanceMeters) {
          bestStopByRouteId[arrival.routeId] = stop;
        }
      }
    }

    final results = <_TrackedAreaVehicle>[];
    final seenVehicleIds = <int>{};
    for (final route in trackedRoutes.routes) {
      final matchedStop = bestStopByRouteId[route.id];
      if (matchedStop == null) {
        continue;
      }

      for (final vehicle in route.activeVehicles) {
        if (!seenVehicleIds.add(vehicle.uid)) {
          continue;
        }
        results.add(
          _TrackedAreaVehicle(
            route: route,
            vehicle: vehicle,
            stop: matchedStop.stop,
            stopDistanceMeters: matchedStop.distanceMeters,
          ),
        );
      }
    }

    const stateOrder = <String, int>{
      'tracking': 0,
      'at_terminal': 1,
      'announced': 2,
      'stale': 3,
    };

    results.sort((left, right) {
      final leftMoving = left.vehicle.moving ? 0 : 1;
      final rightMoving = right.vehicle.moving ? 0 : 1;
      if (leftMoving != rightMoving) {
        return leftMoving.compareTo(rightMoving);
      }

      final leftState = stateOrder[left.vehicle.confidenceState] ?? 9;
      final rightState = stateOrder[right.vehicle.confidenceState] ?? 9;
      if (leftState != rightState) {
        return leftState.compareTo(rightState);
      }

      if (left.stopDistanceMeters != right.stopDistanceMeters) {
        return left.stopDistanceMeters.compareTo(right.stopDistanceMeters);
      }

      final leftSeen = left.vehicle.lastSeenSeconds ?? 1 << 30;
      final rightSeen = right.vehicle.lastSeenSeconds ?? 1 << 30;
      if (leftSeen != rightSeen) {
        return leftSeen.compareTo(rightSeen);
      }

      return '${left.route.routeNumber}|${left.route.routeName}'.compareTo(
        '${right.route.routeNumber}|${right.route.routeName}',
      );
    });

    return results;
  }

  int _compareAreaRouteMatches(_AreaRouteMatch left, _AreaRouteMatch right) {
    const stateOrder = <String, int>{
      'tracking': 0,
      'at_terminal': 1,
      'announced': 2,
      'stale': 3,
    };

    final leftState = stateOrder[left.arrival.confidenceState] ?? 9;
    final rightState = stateOrder[right.arrival.confidenceState] ?? 9;
    if (leftState != rightState) {
      return leftState.compareTo(rightState);
    }

    final leftEta = left.arrival.watchEtaSeconds ?? left.arrival.etaSeconds;
    final rightEta = right.arrival.watchEtaSeconds ?? right.arrival.etaSeconds;
    if (leftEta != rightEta) {
      return leftEta.compareTo(rightEta);
    }

    if (left.stopDistanceMeters != right.stopDistanceMeters) {
      return left.stopDistanceMeters.compareTo(right.stopDistanceMeters);
    }

    return '${left.arrival.routeNumber}|${left.arrival.direction}'.compareTo(
      '${right.arrival.routeNumber}|${right.arrival.direction}',
    );
  }

  _StopDistanceMatch? _closestStopForRoute(
    String routeId,
    AppBootstrap bootstrap,
  ) {
    final nearbyMatch = _nearby?.nearbyStops
        .where((stop) => stop.stop.routes.any((route) => route.id == routeId))
        .toList();
    if (nearbyMatch != null && nearbyMatch.isNotEmpty) {
      nearbyMatch.sort(
        (left, right) => left.distanceMeters.compareTo(right.distanceMeters),
      );
      return _StopDistanceMatch(
        stop: nearbyMatch.first.stop,
        distanceMeters: nearbyMatch.first.distanceMeters,
        inNearbyArea: true,
      );
    }

    final location = _activeLocation;
    if (location == null) {
      return null;
    }

    final userPoint = LatLng(location.lat, location.lng);
    _StopDistanceMatch? best;
    for (final stop in bootstrap.stops) {
      if (!stop.routes.any((route) => route.id == routeId)) {
        continue;
      }
      final distanceMeters = _distanceCalculator
          .as(LengthUnit.Meter, userPoint, LatLng(stop.lat, stop.lng))
          .round();
      if (best == null || distanceMeters < best.distanceMeters) {
        best = _StopDistanceMatch(
          stop: stop,
          distanceMeters: distanceMeters,
          inNearbyArea: false,
        );
      }
    }
    return best;
  }

  int? _distanceToFocusStop(StopSummary stop) {
    final nearbyStop = _nearby?.nearbyStops.where(
      (item) => item.stop.id == stop.id,
    );
    if (nearbyStop != null && nearbyStop.isNotEmpty) {
      return nearbyStop.first.distanceMeters;
    }

    final location = _activeLocation;
    if (location == null) {
      return null;
    }

    return _distanceCalculator
        .as(
          LengthUnit.Meter,
          LatLng(location.lat, location.lng),
          LatLng(stop.lat, stop.lng),
        )
        .round();
  }

  List<_RouteFocusMatch> _routeFocusMatches(AppBootstrap bootstrap) {
    final trackedById = {
      for (final route in _trackedRoutes?.routes ?? const <TrackedRoute>[])
        route.id: route,
    };
    final results = <_RouteFocusMatch>[];

    for (final focus in _routeFocuses) {
      final seenRouteIds = <String>{};
      final matches = bootstrap.routes
          .where((route) => _routeMatchesFocus(route, focus))
          .where((route) => seenRouteIds.add(route.id))
          .toList();
      if (matches.isEmpty) {
        continue;
      }
      final options =
          matches
              .map(
                (route) => _RouteFocusOption(
                  route: route,
                  tracked: trackedById[route.id],
                  closestStop: _closestStopForRoute(route.id, bootstrap),
                ),
              )
              .toList()
            ..sort((left, right) {
              final leftLive = left.tracked?.activeVehicles.length ?? 0;
              final rightLive = right.tracked?.activeVehicles.length ?? 0;
              if (leftLive != rightLive) {
                return rightLive.compareTo(leftLive);
              }

              final leftDist = left.closestStop?.distanceMeters ?? 1 << 30;
              final rightDist = right.closestStop?.distanceMeters ?? 1 << 30;
              return leftDist.compareTo(rightDist);
            });
      results.add(_RouteFocusMatch(label: focus.label, options: options));
    }

    return results;
  }

  bool _routeMatchesFocus(RouteSummary route, _FocusQuery focus) {
    final search = '${route.routeNumber} ${route.routeName} ${route.from} ${route.to}'.toLowerCase();
    final kw = focus.keywords;
    return kw.any((k) => search.contains(k.toLowerCase()));
  }

  List<_StopFocusMatch> _stopFocusMatches(AppBootstrap bootstrap) {
    final results = <_StopFocusMatch>[];
    for (final focus in _stopFocuses) {
      final matches = bootstrap.stops
          .where((stop) => _stopMatchesFocus(stop, focus))
          .toList()
            ..sort((left, right) {
              final leftDistance = _distanceToFocusStop(left) ?? 1 << 30;
              final rightDistance = _distanceToFocusStop(right) ?? 1 << 30;
              return leftDistance.compareTo(rightDistance);
            });
      if (matches.isEmpty) {
        continue;
      }
      results.add(_StopFocusMatch(
        label: focus.label, 
        stop: matches.first,
        distanceMeters: _distanceToFocusStop(matches.first),
      ));
    }
    return results;
  }

  bool _stopMatchesFocus(StopSummary stop, _FocusQuery focus) {
    final search = '${stop.name} ${stop.description}'.toLowerCase();
    final kw = focus.keywords;
    return kw.any((k) => search.contains(k.toLowerCase()));
  }

  List<_WatchIncomingArrival> _watchComingSoon() {
    final byKey = <String, _WatchIncomingArrival>{};

    for (final status in _watchStatuses) {
      for (final arrival in [
        ...status.primaryArrivals,
        ...status.announcedArrivals,
      ]) {
        final effectiveEtaSeconds =
            arrival.watchEtaSeconds ?? arrival.etaSeconds;
        if (effectiveEtaSeconds > _comingSoonWindowSeconds) {
          continue;
        }
        final key = arrival.vehicleUid != null
            ? 'vehicle:${arrival.vehicleUid}'
            : 'route:${arrival.routeId}|${arrival.direction.toLowerCase()}';
        final candidate = _WatchIncomingArrival(
          status: status,
          arrival: arrival,
          latestEvent: _latestWatchEventForArrival(status, arrival),
        );
        final current = byKey[key];
        if (current == null ||
            _compareWatchIncomingArrivals(candidate, current) < 0) {
          byKey[key] = candidate;
        }
      }
    }

    final items = byKey.values.toList()..sort(_compareWatchIncomingArrivals);

    return items;
  }

  int _compareWatchIncomingArrivals(
    _WatchIncomingArrival left,
    _WatchIncomingArrival right,
  ) {
    const stateOrder = <String, int>{
      'tracking': 0,
      'at_terminal': 1,
      'announced': 2,
      'stale': 3,
    };

    final leftState = stateOrder[left.arrival.confidenceState] ?? 9;
    final rightState = stateOrder[right.arrival.confidenceState] ?? 9;
    if (leftState != rightState) {
      return leftState.compareTo(rightState);
    }

    final leftEta = left.arrival.watchEtaSeconds ?? left.arrival.etaSeconds;
    final rightEta = right.arrival.watchEtaSeconds ?? right.arrival.etaSeconds;
    if (leftEta != rightEta) {
      return leftEta.compareTo(rightEta);
    }

    return left.status.stop.name.compareTo(right.status.stop.name);
  }

  List<_AreaAlertEntry> _areaAlerts() {
    final alerts = <_AreaAlertEntry>[];

    for (final status in _watchStatuses) {
      for (final event in status.recentEvents) {
        if (event.kind == 'upstream_pass' ||
            event.kind == 'alert_eta_30m' ||
            event.kind == 'alert_eta_10m' ||
            event.kind == 'alert_eta_5m' ||
            event.kind == 'alert_near_stop' ||
            event.kind == 'observed_pass' ||
            event.kind == 'observed_arrival') {
          alerts.add(_AreaAlertEntry(status: status, event: event));
        }
      }
    }

    alerts.sort((left, right) {
      final leftTime = _tryParseIso(left.event.happenedAt);
      final rightTime = _tryParseIso(right.event.happenedAt);
      final leftMs = leftTime?.millisecondsSinceEpoch ?? 0;
      final rightMs = rightTime?.millisecondsSinceEpoch ?? 0;
      if (leftMs != rightMs) {
        return rightMs.compareTo(leftMs);
      }
      return _watchEventPriority(
        left.event.kind,
      ).compareTo(_watchEventPriority(right.event.kind));
    });

    return _dedupeAreaAlerts(alerts);
  }

  int _distanceMetersToStop(StopSummary stop) {
    for (final nearby in _nearby?.nearbyStops ?? const <NearbyStop>[]) {
      if (nearby.stop.id == stop.id) {
        return nearby.distanceMeters;
      }
    }
    final location = _activeLocation;
    if (location == null) {
      return 1 << 30;
    }
    return _distanceCalculator
        .as(
          LengthUnit.Meter,
          LatLng(location.lat, location.lng),
          LatLng(stop.lat, stop.lng),
        )
        .round();
  }

  /// Same live bus often emits matching events for every watched stop on its
  /// corridor; keep one row (closest stop to you) so the feed is not duplicated.
  List<_AreaAlertEntry> _dedupeAreaAlerts(List<_AreaAlertEntry> alerts) {
    final byKey = <String, _AreaAlertEntry>{};
    for (final entry in alerts) {
      final event = entry.event;
      final String key;
      if (event.vehicleUid != null) {
        final t = _tryParseIso(event.happenedAt);
        final tKey = t == null
            ? event.happenedAt ?? ''
            : '${t.millisecondsSinceEpoch ~/ 1000}';
        key =
            '${event.kind}|${event.vehicleUid}|${event.routeId ?? ''}|$tKey';
      } else {
        key = event.id;
      }
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = entry;
        continue;
      }
      if (_distanceMetersToStop(entry.status.stop) <
          _distanceMetersToStop(existing.status.stop)) {
        byKey[key] = entry;
      }
    }
    final out = byKey.values.toList();
    out.sort((left, right) {
      final leftTime = _tryParseIso(left.event.happenedAt);
      final rightTime = _tryParseIso(right.event.happenedAt);
      final leftMs = leftTime?.millisecondsSinceEpoch ?? 0;
      final rightMs = rightTime?.millisecondsSinceEpoch ?? 0;
      if (leftMs != rightMs) {
        return rightMs.compareTo(leftMs);
      }
      return _watchEventPriority(
        left.event.kind,
      ).compareTo(_watchEventPriority(right.event.kind));
    });
    return out;
  }

  WatchEvent? _latestWatchEventForArrival(
    WatchStopStatus status,
    Arrival arrival,
  ) {
    for (final event in status.recentEvents) {
      final sameVehicle =
          arrival.vehicleUid != null && event.vehicleUid == arrival.vehicleUid;
      final sameRoute =
          event.routeId == arrival.routeId ||
          (event.routeNumber != null &&
              event.routeNumber == arrival.routeNumber &&
              event.routeNumber!.isNotEmpty);

      if ((sameVehicle || sameRoute) &&
          (event.kind == 'alert_near_stop' ||
              event.kind == 'upstream_pass' ||
              event.kind == 'alert_eta_30m' ||
              event.kind == 'alert_eta_10m' ||
              event.kind == 'alert_eta_5m')) {
        return event;
      }
    }
    return null;
  }

  // ignore: unused_element
  String _unusedStatusLineExplicit(Arrival arrival) {
    final etaLabel = formatArrivalEtaForDisplay(arrival);
    final seenLabel = arrival.lastSeenSeconds == null
        ? ''
        : ' â€¢ seen ${arrival.lastSeenSeconds}s ago';
    switch (arrival.confidenceState) {
      case 'tracking':
        return 'ETA $etaLabel$seenLabel';
      case 'at_terminal':
        return 'At terminal â€¢ scheduled ${arrival.scheduledLabel}';
      default:
        return 'Scheduled after ${arrival.scheduledLabel}';
    }
  }

  // ignore: unused_element
  String _statusLineExplicit(Arrival arrival) {
    final etaLabel = formatArrivalEtaForDisplay(arrival);
    final seenLabel = arrival.lastSeenSeconds == null
        ? ''
        : ' â€¢ seen ${arrival.lastSeenSeconds}s ago';
    switch (arrival.confidenceState) {
      case 'tracking':
        return 'ETA $etaLabel$seenLabel';
      case 'at_terminal':
        return 'At terminal â€¢ scheduled ${arrival.scheduledLabel}';
      default:
        return 'Scheduled after ${arrival.scheduledLabel}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final bootstrap = ref.watch(bootstrapProvider);

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: bootstrap.when(
        data: (bootstrapData) {
          final routeFocusMatches = _routeFocusMatches(bootstrapData);
          final stopFocusMatches = _stopFocusMatches(bootstrapData);
          final comingSoon = _watchComingSoon();
          final areaAlerts = _areaAlerts();
          final areaRoutes = _areaRouteMatches();
          final trackedAreaVehicles = _trackedAreaVehicles();
          final trackedByRouteId = {
            for (final route
                in _trackedRoutes?.routes ?? const <TrackedRoute>[])
              route.id: route,
          };

          return Stack(
            children: [
              // ðŸ—ºï¸ Layer 0: The Map Base
              Positioned.fill(
                child: _LiveMapPanel(
                  location: _activeLocation,
                  nearby: _nearby,
                  areaRoutes: areaRoutes,
                  trackedByRouteId: trackedByRouteId,
                  trackedRouteVehicles: trackedAreaVehicles,
                  radiusMeters: _radiusMeters,
                  now: _uiNow,
                  referenceTime: _lastRefreshAt,
                  refreshHintSeconds: _nearby?.refreshHintSeconds ?? 5,
                  onLocate: _refresh,
                ),
              ),

              // ðŸ›°ï¸ Layer 1: Floating Header Row
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Left: Settings/Alerts
                        AppBarBackAction(fallbackLocation: '/'),
                        // Right: Search
                        IconButton(
                          tooltip: 'Search Routes & Stops',
                          style: IconButton.styleFrom(
                            foregroundColor: Colors.white,
                            backgroundColor: const Color(0xFF0D1B2A).withValues(alpha: 0.6),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                            ),
                            padding: const EdgeInsets.all(10),
                            minimumSize: const Size(44, 44),
                          ),
                          icon: const Icon(Icons.search_rounded, size: 22),
                          onPressed: () => context.push('/search'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // ðŸ“‹ Layer 2: Draggable Information Sheet
              DraggableScrollableSheet(
                initialChildSize: 0.28,
                minChildSize: 0.12,
                maxChildSize: 0.94,
                snap: true,
                snapSizes: const [0.12, 0.28, 0.94],
                builder: (context, scrollController) {
                  return ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(36),
                      topRight: Radius.circular(36),
                    ),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF0D1B2A).withValues(alpha: 0.75),
                          border: Border(
                            top: BorderSide(
                              color: Colors.white.withValues(alpha: 0.1),
                              width: 1,
                            ),
                          ),
                        ),
                        child: RefreshIndicator(
                          onRefresh: _refresh,
                          displacement: 20,
                          child: ListView(
                            controller: scrollController,
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 60),
                            children: [
                              const _SheetHandle(),
                              
                              // Quick Status Hero
                              _LiveEtaHero(
                                locationStatus: _locationStatus ?? LocationStatus.available,
                                radius: _radiusMeters,
                                trackedCount: _trackedRoutes?.vehicleCount ?? 0,
                                notificationLabel: _notificationSetup.label,
                              ),
                          
                          if (_message != null) ...[
                            const SizedBox(height: 18),
                            SectionCard(
                              child: Text(
                                _message!,
                                style: Theme.of(context).textTheme.bodyLarge,
                              ),
                            ),
                          ],
                          
                          if (_nearby != null) ...[
                            const SizedBox(height: 18),
                            _AreaRoutesSection(
                              items: areaRoutes,
                              trackedByRouteId: trackedByRouteId,
                              now: _uiNow,
                              referenceTime: _lastRefreshAt,
                            ),
                          ],
                          
                          if (_watchStatuses.isNotEmpty) ...[
                            const SizedBox(height: 18),
                            _AreaAlertsSection(alerts: areaAlerts),
                            const SizedBox(height: 18),
                            _ComingSoonSection(
                              items: comingSoon,
                              notificationSetup: _notificationSetup,
                              onEnableAlerts: _enablePhoneAlerts,
                              enabledReminderMinutes: _enabledReminderMinutes,
                              onToggleReminderMinute: _toggleReminderMinute,
                              now: _uiNow,
                              referenceTime: _lastRefreshAt,
                            ),
                            const SizedBox(height: 18),
                            _WatchDetailsSection(
                              statuses: _watchStatuses,
                              now: _uiNow,
                              referenceTime: _lastRefreshAt,
                            ),
                          ],
                          
                          if (_trackedRoutes != null || routeFocusMatches.isNotEmpty || stopFocusMatches.isNotEmpty) ...[
                            const SizedBox(height: 18),
                            _ExploreMoreSection(
                              tracked: _trackedRoutes,
                              routeMatches: routeFocusMatches,
                              stopMatches: stopFocusMatches,
                              location: _activeLocation,
                            ),
                          ],
                          
                          if (_isLoading && _nearby == null)
                            const Padding(
                              padding: EdgeInsets.only(top: 40),
                              child: Center(child: CircularProgressIndicator()),
                            )
                          else if (_nearby == null)
                             const _LocationWaitCard(),

                          if (_nearby != null && _nearby!.nearbyStops.isEmpty) ...[
                             const SizedBox(height: 18),
                             SectionCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'No nearby stops inside ${_radiusMeters}m',
                                    style: Theme.of(context).textTheme.titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    'Try wider radius. Search stays there if you want a specific bus.',
                                    style: Theme.of(context).textTheme.bodyLarge,
                                  ),
                                  const SizedBox(height: 18),
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 12,
                                    children: [
                                      FilledButton(
                                        onPressed: () =>
                                            _refresh(forceRadiusExpansion: true),
                                        child: const Text('Try 1500m'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],

                          if (_nearby != null && _nearby!.nearbyStops.isNotEmpty) ...[
                            const SizedBox(height: 18),
                            _NearbyStopsSection(
                              liveStops: _stopsWithPrimary().toList(),
                              announcedStops: _stopsWithAnnounced().toList(),
                              now: _uiNow,
                              referenceTime: _lastRefreshAt,
                            ),
                          ],

                          if (_recentStops(bootstrapData).isNotEmpty) ...[
                            const SizedBox(height: 18),
                            SectionCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Recent Stops',
                                    style: Theme.of(context).textTheme.titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 14),
                                  ..._recentStops(bootstrapData).map(
                                    (stop) => ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(stop.name),
                                      subtitle: Text(
                                        stop.description.isEmpty
                                            ? 'Saved stop'
                                            : stop.description,
                                      ),
                                      trailing: const Icon(Icons.chevron_right_rounded),
                                      onTap: () => context.push('/stops/${stop.id}'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
                },
              ),
            ],
          );
        },
        loading: () => const AppBackground(
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, _) => AppBackground(
          child: Center(child: Text('Error: $error')),
        ),
      ),
    );
  }
}

class _LiveMapPanel extends StatefulWidget {
  const _LiveMapPanel({
    required this.location,
    required this.nearby,
    required this.areaRoutes,
    required this.trackedByRouteId,
    required this.trackedRouteVehicles,
    required this.radiusMeters,
    required this.now,
    required this.referenceTime,
    required this.refreshHintSeconds,
    required this.onLocate,
  });

  final SavedLocation? location;
  final NearbyResponse? nearby;
  final List<_AreaRouteMatch> areaRoutes;
  final Map<String, TrackedRoute> trackedByRouteId;
  final List<_TrackedAreaVehicle> trackedRouteVehicles;
  final int radiusMeters;
  final DateTime now;
  final DateTime? referenceTime;
  final int refreshHintSeconds;
  final Future<void> Function() onLocate;

  @override
  State<_LiveMapPanel> createState() => _LiveMapPanelState();
}

class _LiveMapPanelState extends State<_LiveMapPanel>
    with AutomaticKeepAliveClientMixin<_LiveMapPanel> {
  final MapController _mapController = MapController();
  int? _selectedVehicleUid;
  bool _mapReady = false;
  bool _didFitInitialView = false;
  bool _didFitUserOnce = false;
  bool _followSelectedVehicle = false;
  double _lastZoom = 14.8;
  _SurfaceStatusFilter _selectedFilter = _SurfaceStatusFilter.all;

  @override
  bool get wantKeepAlive => true;

  NearbyResponse? get _nearby => widget.nearby;

  List<Vehicle> get _vehicles => _nearby?.nearbyVehicles ?? const <Vehicle>[];

  List<Vehicle> get _allVehicles {
    final byUid = <int, Vehicle>{};
    for (final vehicle in _vehicles) {
      byUid[vehicle.uid] = vehicle;
    }
    for (final tracked in widget.trackedRouteVehicles) {
      byUid.putIfAbsent(tracked.vehicle.uid, () => tracked.vehicle);
    }
    final results = byUid.values.toList()
      ..sort((left, right) {
        final leftState = left.confidenceState == 'tracking'
            ? 0
            : left.confidenceState == 'at_terminal'
            ? 1
            : 2;
        final rightState = right.confidenceState == 'tracking'
            ? 0
            : right.confidenceState == 'at_terminal'
            ? 1
            : 2;
        if (leftState != rightState) {
          return leftState.compareTo(rightState);
        }
        if (left.moving != right.moving) {
          return right.moving ? 1 : -1;
        }
        final leftSeen = left.lastSeenSeconds ?? 1 << 30;
        final rightSeen = right.lastSeenSeconds ?? 1 << 30;
        if (leftSeen != rightSeen) {
          return leftSeen.compareTo(rightSeen);
        }
        return '${left.routeNumber}|${left.routeDirection}'.compareTo(
          '${right.routeNumber}|${right.routeDirection}',
        );
      });
    return results;
  }

  List<_TrackedAreaVehicle> get _extraTrackedVehicles => widget
      .trackedRouteVehicles
      .where(
        (tracked) =>
            !_vehicles.any((vehicle) => vehicle.uid == tracked.vehicle.uid),
      )
      .toList();

  List<Vehicle> _vehiclesForFilter(_SurfaceStatusFilter filter) {
    if (filter == _SurfaceStatusFilter.all) {
      return _allVehicles;
    }
    return _allVehicles
        .where(
          (vehicle) => _matchesStatusFilter(vehicle.confidenceState, filter),
        )
        .toList();
  }

  List<_AreaRouteMatch> get _scheduledAreaRoutes {
    final routes =
        widget.areaRoutes
            .where(
              (item) =>
                  _effectiveAreaRouteState(item, widget.trackedByRouteId) ==
                  'announced',
            )
            .toList()
          ..sort((left, right) {
            final leftEta =
                left.arrival.watchEtaSeconds ?? left.arrival.etaSeconds;
            final rightEta =
                right.arrival.watchEtaSeconds ?? right.arrival.etaSeconds;
            if (leftEta != rightEta) {
              return leftEta.compareTo(rightEta);
            }
            return left.stopDistanceMeters.compareTo(right.stopDistanceMeters);
          });
    return routes;
  }

  Vehicle? get _selectedVehicle {
    if (_selectedVehicleUid == null) {
      return null;
    }
    for (final vehicle in _allVehicles) {
      if (vehicle.uid == _selectedVehicleUid) {
        return vehicle;
      }
    }
    return null;
  }

  LatLng _center() {
    final location = widget.location;
    if (location != null) {
      return LatLng(location.lat, location.lng);
    }
    if (_nearby != null && _nearby!.nearbyStops.isNotEmpty) {
      final stop = _nearby!.nearbyStops.first.stop;
      return LatLng(stop.lat, stop.lng);
    }
    return _defaultIslandCenter;
  }

  String? _destinationFromDirection(String? direction) {
    if (direction == null || direction.isEmpty) {
      return null;
    }

    final lower = direction.toLowerCase();
    if (lower.contains(' towards ')) {
      return direction
          .split(RegExp(r'\s+towards\s+', caseSensitive: false))
          .last;
    }
    if (direction.contains('->')) {
      return direction.split('->').last.trim();
    }
    if (lower.contains(' to ')) {
      return direction.split(RegExp(r'\s+to\s+', caseSensitive: false)).last;
    }
    return direction;
  }

  String _vehicleTitle(Vehicle vehicle) {
    final destination = _destinationFromDirection(vehicle.routeDirection);
    if (destination != null && destination.isNotEmpty) {
      return 'Toward $destination';
    }
    if (vehicle.derivedRouteName != null &&
        vehicle.derivedRouteName!.isNotEmpty) {
      return vehicle.derivedRouteName!;
    }
    return vehicle.routeDirection.isEmpty
        ? 'Tracked bus'
        : vehicle.routeDirection;
  }

  // ignore: unused_element
  String _vehicleMeta(Vehicle vehicle) {
    final parts = <String>[];
    if (vehicle.distanceMeters != null) {
      parts.add('${vehicle.distanceMeters} m from you');
    }
    final speed = vehicle.position.speedKph;
    if (speed != null) {
      parts.add('${speed.toStringAsFixed(0)} km/h');
    }
    if (vehicle.lastSeenSeconds != null) {
      parts.add('seen ${vehicle.lastSeenSeconds}s ago');
    }
    return parts.isEmpty ? vehicle.statusText : parts.join(' â€¢ ');
  }

  // ignore: unused_element
  String _liveVehicleMeta(Vehicle vehicle, {SavedLocation? user}) {
    final parts = <String>[];
    final rel = _busRelativeToUser(vehicle, user);
    final dist = _effectiveDistanceUserToVehicle(vehicle, user);

    if (user != null && dist != null) {
      if (rel == _BusUserRelative.passed) {
        parts.add('Passed you â€” moving away (opposite direction)');
      } else if (rel == _BusUserRelative.approaching) {
        final eta = _estimateSecondsToReachUser(
          distanceMeters: dist,
          speedKph: vehicle.position.speedKph,
          rel: rel,
        );
        if (eta != null) {
          parts.add('Reach you in ~${formatDurationHms(eta)}');
        }
      }
    }

    final lineDist = dist ?? vehicle.distanceMeters;
    if (lineDist != null) {
      parts.add('$lineDist m from you');
    }
    final speed = vehicle.position.speedKph;
    if (speed != null) {
      parts.add('${speed.toStringAsFixed(0)} km/h');
    }
    final seenSeconds = _liveSeenSeconds(
      baseSeconds: vehicle.lastSeenSeconds,
      now: widget.now,
      referenceTime: widget.referenceTime,
    );
    if (seenSeconds != null) {
      parts.add('ping ${seenSeconds}s ago');
    }
    return parts.isEmpty ? vehicle.statusText : parts.join(' | ');
  }

  LatLng _vehiclePoint(Vehicle vehicle) {
    final previous = vehicle.previousPosition;
    if (previous == null || vehicle.confidenceState != 'tracking') {
      return LatLng(vehicle.position.lat, vehicle.position.lng);
    }

    if (widget.referenceTime == null) {
      return LatLng(vehicle.position.lat, vehicle.position.lng);
    }

    final elapsedMs = widget.now
        .difference(widget.referenceTime!)
        .inMilliseconds;
    final windowMs = widget.refreshHintSeconds <= 2 ? 1200.0 : 2200.0;
    final progress = (elapsedMs / windowMs).clamp(0.0, 1.0);
    final lat =
        previous.lat + ((vehicle.position.lat - previous.lat) * progress);
    final lng =
        previous.lng + ((vehicle.position.lng - previous.lng) * progress);
    return LatLng(lat, lng);
  }

  String _coordinateLabel(Vehicle vehicle) {
    return '${vehicle.position.lat.toStringAsFixed(5)}, ${vehicle.position.lng.toStringAsFixed(5)}';
  }

  int _filterCount(_SurfaceStatusFilter filter) {
    if (filter == _SurfaceStatusFilter.announced) {
      return _scheduledAreaRoutes.length;
    }
    if (filter == _SurfaceStatusFilter.all) {
      return _allVehicles.length + _scheduledAreaRoutes.length;
    }
    return _vehiclesForFilter(filter).length;
  }

  void _setFilter(_SurfaceStatusFilter filter) {
    final selectedVehicle = _selectedVehicle;
    setState(() {
      _selectedFilter = filter;
      if (selectedVehicle != null &&
          filter != _SurfaceStatusFilter.all &&
          !_matchesStatusFilter(selectedVehicle.confidenceState, filter)) {
        _selectedVehicleUid = null;
        _followSelectedVehicle = false;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncCameraFromLatestData();
      }
    });
  }

  Widget _vehicleQuickCard(BuildContext context, Vehicle vehicle) {
    final user = widget.location;
    final rel = _busRelativeToUser(vehicle, user);
    final Color cardBg;
    final BoxBorder? cardBorder;
    switch (rel) {
      case _BusUserRelative.passed:
        cardBg = const Color(0xFFFF5252).withValues(alpha: 0.08);
        cardBorder = Border.all(
          color: const Color(0xFFFF5252).withValues(alpha: 0.2),
          width: 1,
        );
        break;
      case _BusUserRelative.approaching:
        cardBg = const Color(0xFF00E5FF).withValues(alpha: 0.06);
        cardBorder = Border.all(
          color: const Color(0xFF00E5FF).withValues(alpha: 0.25),
          width: 0.8,
        );
        break;
      case _BusUserRelative.unknown:
        cardBg = Colors.white.withValues(alpha: 0.03);
        cardBorder = Border.all(
          color: Colors.white.withValues(alpha: 0.05),
          width: 0.5,
        );
        break;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _focusVehicle(vehicle),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(18),
          border: cardBorder,
        ),
        child: Row(
          children: [
            RoutePill(
              label: vehicle.routeNumber.isEmpty ? 'Bus' : vehicle.routeNumber,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _vehicleTitle(vehicle),
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _liveVehicleMeta(vehicle, user: user),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: rel == _BusUserRelative.passed
                          ? const Color(0xFFFF8A80)
                          : rel == _BusUserRelative.approaching
                              ? const Color(0xFF00E5FF)
                              : Colors.white70,
                      fontWeight: rel != _BusUserRelative.unknown ? FontWeight.w700 : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Click to track on map',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.gps_fixed_rounded, size: 18),
            const SizedBox(width: 8),
            if (rel == _BusUserRelative.passed)
              const ToneChip(
                label: 'Passed you?',
                color: Color(0xFF9B2E2E),
              )
            else
              ConfidenceChip(
                state: vehicle.confidenceState,
                label: vehicle.statusText,
              ),
          ],
        ),
      ),
    );
  }

  Widget _trackedRouteQuickCard(
    BuildContext context,
    _TrackedAreaVehicle tracked,
  ) {
    final movingLabel = tracked.vehicle.moving ? 'moving now' : 'tracked now';
    final rel = _busRelativeToUser(tracked.vehicle, widget.location);
    final Color cardBg;
    final BoxBorder? cardBorder;
    switch (rel) {
      case _BusUserRelative.passed:
        cardBg = const Color(0xFF9B2E2E).withValues(alpha: 0.16);
        cardBorder = Border.all(color: const Color(0x66C62828), width: 1.5);
        break;
      case _BusUserRelative.approaching:
        cardBg =
            confidenceColor(tracked.vehicle.confidenceState).withValues(alpha: 0.14);
        cardBorder = Border.all(color: const Color(0x440B7A75), width: 1);
        break;
      case _BusUserRelative.unknown:
        cardBg = confidenceColor(
          tracked.vehicle.confidenceState,
        ).withValues(alpha: 0.10);
        cardBorder = null;
        break;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _focusVehicle(tracked.vehicle),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(18),
          border: cardBorder,
        ),
        child: Row(
          children: [
            RoutePill(
              label: tracked.route.routeNumber.isEmpty
                  ? 'Bus'
                  : tracked.route.routeNumber,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _vehicleTitle(tracked.vehicle),
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${tracked.route.routeName} â€¢ serves ${tracked.stop.name}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_formatDistanceLabel(tracked.stopDistanceMeters)} away â€¢ $movingLabel â€¢ ${_liveVehicleMeta(tracked.vehicle, user: widget.location)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: rel == _BusUserRelative.passed
                          ? const Color(0xFF7A1F1F)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Click to track on map',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (rel == _BusUserRelative.passed)
              const ToneChip(
                label: 'Passed you?',
                color: Color(0xFF9B2E2E),
              )
            else
              ConfidenceChip(
                state: tracked.vehicle.confidenceState,
                label: tracked.vehicle.statusText,
              ),
          ],
        ),
      ),
    );
  }

  Widget _announcedRouteQuickCard(BuildContext context, _AreaRouteMatch item) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => context.push(_routePath(item.arrival.routeId)),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FBFB),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RoutePill(label: item.arrival.routeNumber),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.arrival.routeName,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Closest stop ${item.stop.name} â€¢ ${_formatDistanceLabel(item.stopDistanceMeters)} away',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Scheduled after ${item.arrival.scheduledLabel}',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            ConfidenceChip(state: 'announced', label: item.arrival.statusText),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(BuildContext context, _SurfaceStatusFilter filter) {
    final selected = _selectedFilter == filter;
    final state = switch (filter) {
      _SurfaceStatusFilter.all => 'tracking',
      _SurfaceStatusFilter.tracking => 'tracking',
      _SurfaceStatusFilter.atTerminal => 'at_terminal',
      _SurfaceStatusFilter.announced => 'announced',
    };

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _setFilter(filter),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? confidenceColor(state).withValues(alpha: 0.88)
              : confidenceColor(state).withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? Colors.white : Colors.transparent,
            width: 1.4,
          ),
        ),
        child: Text(
          '${_surfaceStatusFilterLabel(filter)} ${_filterCount(filter)}',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: selected ? Colors.white : confidenceColor(state),
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  List<LatLng> _contextCoordinates() {
    final points = <LatLng>[];
    final location = widget.location;
    if (location != null) {
      points.add(LatLng(location.lat, location.lng));
    }

    if (_nearby != null) {
      for (final stop in _nearby!.nearbyStops.take(8)) {
        points.add(LatLng(stop.stop.lat, stop.stop.lng));
      }
      for (final vehicle in _allVehicles.take(12)) {
        points.add(LatLng(vehicle.position.lat, vehicle.position.lng));
      }
    }

    return points;
  }

  void _fitToContext() {
    if (!_mapReady) {
      return;
    }

    final points = _contextCoordinates();
    if (points.isEmpty) {
      _mapController.move(
        _center(),
        widget.location != null ? 14.3 : 12.8,
        id: 'default-area',
      );
      return;
    }

    if (points.length == 1) {
      _mapController.move(
        points.first,
        widget.location != null ? 14.8 : 13.4,
        id: 'single-point',
      );
      return;
    }

    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: points,
        padding: const EdgeInsets.fromLTRB(44, 80, 44, 260),
        maxZoom: widget.location != null ? 15.2 : 14.0,
        minZoom: widget.location != null ? 12.2 : 10.8,
      ),
    );
  }

  void _focusVehicle(Vehicle vehicle) {
    setState(() {
      _selectedVehicleUid = vehicle.uid;
      _followSelectedVehicle = false;
      _didFitInitialView = true;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mapReady) {
        return;
      }
      final busPoint = _vehiclePoint(vehicle);
      final loc = widget.location;
      if (loc != null) {
        final userPoint = LatLng(loc.lat, loc.lng);
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: [busPoint, userPoint],
            padding: const EdgeInsets.fromLTRB(44, 100, 44, 320),
            maxZoom: 17.2,
            minZoom: 12.8,
          ),
        );
        try {
          _lastZoom = _mapController.camera.zoom;
        } catch (_) {
          _lastZoom = 15.8;
        }
      } else {
        final zoom = (_lastZoom < 16.2 ? 16.2 : _lastZoom).clamp(15.4, 17.8);
        _lastZoom = zoom;
        _mapController.move(
          busPoint,
          zoom,
          id: 'focus-${vehicle.uid}',
        );
      }
    });
  }

  void _startFollowSelectedBus() {
    final selected = _selectedVehicle;
    if (selected == null) {
      return;
    }
    final zoom = (_lastZoom < 16.2 ? 16.2 : _lastZoom).clamp(15.4, 17.8);
    setState(() {
      _followSelectedVehicle = true;
      _lastZoom = zoom;
    });
    if (_mapReady) {
      _mapController.move(
        _vehiclePoint(selected),
        zoom,
        id: 'follow-${selected.uid}',
      );
    }
  }

  void _clearFocus() {
    setState(() {
      _selectedVehicleUid = null;
      _followSelectedVehicle = false;
      _didFitInitialView = true;
    });
    _fitToContext();
  }

  Future<void> _refreshAndReset() async {
    setState(() {
      _selectedVehicleUid = null;
      _followSelectedVehicle = false;
      _didFitInitialView = false;
    });
    await widget.onLocate();
    if (!mounted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncCameraFromLatestData();
      }
    });
  }

  void _syncCameraFromLatestData() {
    if (!_mapReady) {
      return;
    }

    final selected = _selectedVehicle;
    if (_selectedVehicleUid != null && selected == null) {
      setState(() {
        _selectedVehicleUid = null;
        _followSelectedVehicle = false;
      });
    }

    if (selected != null && _followSelectedVehicle) {
      final zoom = (_lastZoom < 16.2 ? 16.2 : _lastZoom).clamp(15.4, 17.8);
      _mapController.move(
        _vehiclePoint(selected),
        zoom,
        id: 'follow-${selected.uid}',
      );
      return;
    }

    if (!_didFitInitialView) {
      _didFitInitialView = true;
      if (widget.location != null) {
        _didFitUserOnce = true;
      }
      _fitToContext();
    } else if (widget.location != null && !_didFitUserOnce) {
      _didFitUserOnce = true;
      _fitToContext();
    }
  }

  @override
  void didUpdateWidget(covariant _LiveMapPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncCameraFromLatestData();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final nearby = _nearby;
    final location = widget.location;
    final selectedVehicle = _selectedVehicle;
    final filteredNearbyVehicles = _selectedFilter == _SurfaceStatusFilter.all
        ? _vehicles
        : _vehicles
              .where(
                (vehicle) => _matchesStatusFilter(
                  vehicle.confidenceState,
                  _selectedFilter,
                ),
              )
              .toList();
    final filteredExtraTrackedVehicles =
        _selectedFilter == _SurfaceStatusFilter.all
        ? _extraTrackedVehicles
        : _extraTrackedVehicles
              .where(
                (tracked) => _matchesStatusFilter(
                  tracked.vehicle.confidenceState,
                  _selectedFilter,
                ),
              )
              .toList();
    final filteredMapVehicles = <Vehicle>[
      ...filteredNearbyVehicles,
      ...filteredExtraTrackedVehicles
          .where(
            (tracked) => !filteredNearbyVehicles.any(
              (vehicle) => vehicle.uid == tracked.vehicle.uid,
            ),
          )
          .map((tracked) => tracked.vehicle),
    ];
    final otherVehicles = selectedVehicle == null
        ? filteredNearbyVehicles
        : filteredNearbyVehicles
              .where((vehicle) => vehicle.uid != selectedVehicle.uid)
              .toList();
    final otherTrackedRouteVehicles = selectedVehicle == null
        ? filteredExtraTrackedVehicles
        : filteredExtraTrackedVehicles
              .where((tracked) => tracked.vehicle.uid != selectedVehicle.uid)
              .toList();
    final nearMeStatusLine = nearby == null
        ? 'Waiting for location and nearby live view.'
        : selectedVehicle != null
        ? 'Focused on ${selectedVehicle.routeNumber.isEmpty ? 'tracked bus' : selectedVehicle.routeNumber}'
        : _selectedFilter == _SurfaceStatusFilter.announced
        ? _scheduledAreaRoutes.isNotEmpty
              ? '${_scheduledAreaRoutes.length} schedule-only routes near you right now'
              : 'No schedule-only routes near you right now.'
        : filteredNearbyVehicles.isNotEmpty &&
              filteredExtraTrackedVehicles.isNotEmpty
        ? '${filteredNearbyVehicles.length} nearby live | ${filteredExtraTrackedVehicles.length} more on your routes'
        : filteredNearbyVehicles.isNotEmpty
        ? '${filteredNearbyVehicles.length} nearby live buses showing on map'
        : filteredExtraTrackedVehicles.isNotEmpty
        ? '${filteredExtraTrackedVehicles.length} buses on your routes showing on map'
        : _emptyNearbyMapMessage(_selectedFilter);
    final focusUserRel = selectedVehicle != null
        ? _busRelativeToUser(selectedVehicle, location)
        : _BusUserRelative.unknown;

    return Stack(
      children: [
        Positioned.fill(
          child: Stack(
            children: [
              FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _center(),
                    initialZoom: location != null ? 14.3 : 12.8,
                    keepAlive: true,
                    onMapReady: () {
                      _mapReady = true;
                      _syncCameraFromLatestData();
                    },
                    onTap: (_, point) {
                      if (_selectedVehicleUid != null) {
                        setState(() {
                          _selectedVehicleUid = null;
                          _followSelectedVehicle = false;
                        });
                      }
                    },
                    onPositionChanged: (camera, hasGesture) {
                      _lastZoom = camera.zoom;
                      if (hasGesture && _followSelectedVehicle) {
                        setState(() {
                          _followSelectedVehicle = false;
                        });
                      }
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://cartodb-basemaps-a.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png',
                      userAgentPackageName: 'barbados_bus_demo',
                    ),
                    if (filteredMapVehicles.isNotEmpty)
                      PolylineLayer(
                        polylines: filteredMapVehicles
                            .where(
                              (vehicle) => vehicle.previousPosition != null,
                            )
                            .map(
                              (vehicle) => Polyline(
                                points: [
                                  LatLng(
                                    vehicle.previousPosition!.lat,
                                    vehicle.previousPosition!.lng,
                                  ),
                                  LatLng(
                                    vehicle.position.lat,
                                    vehicle.position.lng,
                                  ),
                                ],
                                strokeWidth: 4,
                                color: confidenceColor(
                                  vehicle.confidenceState,
                                ).withValues(alpha: 0.35),
                              ),
                            )
                            .toList(),
                      ),
                    if (nearby != null)
                      MarkerLayer(
                        markers: nearby.nearbyStops
                            .map(
                              (stop) => Marker(
                                point: LatLng(stop.stop.lat, stop.stop.lng),
                                width: 28,
                                height: 28,
                                child: StopMapMarker(
                                  routeCount: stop.stop.routes.length,
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    if (filteredMapVehicles.isNotEmpty)
                      MarkerLayer(
                        markers: filteredMapVehicles
                            .map(
                              (vehicle) => Marker(
                                point: _vehiclePoint(vehicle),
                                width: vehicle.uid == _selectedVehicleUid
                                    ? 90
                                    : 76,
                                height: vehicle.uid == _selectedVehicleUid
                                    ? 90
                                    : 76,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _focusVehicle(vehicle),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      boxShadow:
                                          vehicle.uid == _selectedVehicleUid
                                          ? const [
                                              BoxShadow(
                                                color: Color(0x330B7A75),
                                                blurRadius: 18,
                                                spreadRadius: 6,
                                              ),
                                            ]
                                          : const [],
                                    ),
                                    child: BusPulseMarker(
                                      state: vehicle.confidenceState,
                                      routeLabel: vehicle.routeNumber,
                                    ),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    if (location != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: LatLng(location.lat, location.lng),
                            width: 44,
                            height: 44,
                            child: const UserLocationMarker(),
                          ),
                        ],
                      ),
                  ],
                ),
                Positioned(
                  top: 14,
                  left: 14,
                  right: 14,
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xB5132221),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Near Me',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                nearMeStatusLine,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filledTonal(
                        onPressed: _refreshAndReset,
                        icon: const Icon(Icons.gps_fixed_rounded),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 14,
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: _SurfaceStatusFilter.values
                        .map((filter) => _filterChip(context, filter))
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ComingSoonSection extends StatelessWidget {
  const _ComingSoonSection({
    required this.items,
    required this.notificationSetup,
    required this.onEnableAlerts,
    required this.enabledReminderMinutes,
    required this.onToggleReminderMinute,
    required this.now,
    required this.referenceTime,
  });

  final List<_WatchIncomingArrival> items;
  final NotificationSetup notificationSetup;
  final Future<void> Function() onEnableAlerts;
  final Set<int> enabledReminderMinutes;
  final Future<void> Function(int minute) onToggleReminderMinute;
  final DateTime now;
  final DateTime? referenceTime;

  String? _destinationFromDirection(String? direction) {
    if (direction == null || direction.isEmpty) {
      return null;
    }

    final lower = direction.toLowerCase();
    if (lower.contains(' towards ')) {
      return direction
          .split(RegExp(r'\s+towards\s+', caseSensitive: false))
          .last;
    }
    if (direction.contains('->')) {
      return direction.split('->').last.trim();
    }
    if (lower.contains(' to ')) {
      return direction.split(RegExp(r'\s+to\s+', caseSensitive: false)).last;
    }
    return direction;
  }

  String _directionLine(Arrival arrival) {
    final destination = _destinationFromDirection(arrival.direction);
    if (destination == null || destination.isEmpty) {
      return arrival.routeName;
    }
    return 'Toward $destination';
  }

  // ignore: unused_element
  String _statusLine(Arrival arrival) {
    switch (arrival.confidenceState) {
      case 'tracking':
        return 'Tracking â€¢ ${formatArrivalEtaForDisplay(arrival)}';
      case 'at_terminal':
        return 'At terminal â€¢ scheduled ${arrival.scheduledLabel}';
      default:
        return 'Announced â€¢ after ${arrival.scheduledLabel}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Coming Through Your Area',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Closest live stops around you stay watched automatically. Tap bus row to open route map and see exactly where it is.',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (notificationSetup.needsPermission)
                FilledButton.icon(
                  onPressed: () => onEnableAlerts(),
                  icon: const Icon(Icons.notifications_active_rounded),
                  label: const Text('Phone Alerts'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              const ToneChip(label: '30m window', color: Color(0xFF355C7D)),
              ToneChip(
                label: '${items.length} coming soon',
                color: const Color(0xFF0B7A75),
              ),
              ToneChip(
                label: notificationSetup.label,
                color: notificationSetup.granted
                    ? const Color(0xFF0B7A75)
                    : notificationSetup.supported
                    ? const Color(0xFF9B4D3D)
                    : const Color(0xFFE09F27),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Reminder windows',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [30, 10, 5]
                .map(
                  (minute) => FilterChip(
                    label: Text('${minute}m'),
                    selected: enabledReminderMinutes.contains(minute),
                    onSelected: (_) => onToggleReminderMinute(minute),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 16),
          if (items.isEmpty)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FBFB),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                'No local bus inside 30 minute window yet. Area alerts still fire when telemetry sees one near or passing your stop.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            )
          else
            ...items
                .take(6)
                .map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => context.push(
                        _routePath(
                          item.arrival.routeId,
                          vehicleUid: item.arrival.vehicleUid,
                        ),
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: confidenceColor(
                            item.arrival.confidenceState,
                          ).withValues(alpha: 0.11),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            RoutePill(label: item.arrival.routeNumber),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.status.stop.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _directionLine(item.arrival),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: const Color(0xFF355C7D),
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _explicitArrivalStatusLine(
                                      item.arrival,
                                      now,
                                      referenceTime,
                                    ),
                                    style: Theme.of(context).textTheme.bodyLarge
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  if (item.arrival.confidenceState ==
                                          'tracking' &&
                                      item.arrival.rawEtaLabel != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      'Rounded ETA was ${item.arrival.rawEtaLabel}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                  if (item.latestEvent != null) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      'Latest ping: ${item.latestEvent!.message}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            ConfidenceChip(
                              state: item.arrival.confidenceState,
                              label: item.arrival.statusText,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

class _AreaAlertsSection extends StatelessWidget {
  const _AreaAlertsSection({required this.alerts});

  final List<_AreaAlertEntry> alerts;

  String _metaLine(BuildContext context, _AreaAlertEntry alert) {
    final parts = <String>[alert.status.stop.name];
    final happenedAt = _tryParseIso(alert.event.happenedAt);
    if (happenedAt != null) {
      final timeOfDay = TimeOfDay.fromDateTime(happenedAt.toLocal());
      parts.add(
        MaterialLocalizations.of(
          context,
        ).formatTimeOfDay(timeOfDay, alwaysUse24HourFormat: false),
      );
    }
    if (alert.event.destinationName != null &&
        alert.event.destinationName!.trim().isNotEmpty) {
      parts.add('Toward ${alert.event.destinationName}');
    }
    return parts.join(' | ');
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Latest Area Alerts',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'Missed banner or sound? Most recent pass and coming-soon updates stay here. One bus on multiple watched stops is folded into a single line.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 14),
          if (alerts.isEmpty)
            Text(
              'No fresh area alerts yet.',
              style: Theme.of(context).textTheme.bodyLarge,
            )
          else
            ...alerts
                .take(3)
                .map(
                  (alert) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () {
                        final routeId = alert.event.routeId;
                        if (routeId != null && routeId.isNotEmpty) {
                          context.push(
                            _routePath(
                              routeId,
                              vehicleUid: alert.event.vehicleUid,
                            ),
                          );
                          return;
                        }
                        context.push('/stops/${alert.status.stop.id}');
                      },
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _watchEventColor(
                            alert.event.kind,
                          ).withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              _watchEventIcon(alert.event.kind),
                              color: _watchEventColor(alert.event.kind),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    alert.event.message,
                                    style: Theme.of(context).textTheme.bodyLarge
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _metaLine(context, alert),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Icon(Icons.chevron_right_rounded),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

class _WatchDetailsSection extends StatelessWidget {
  const _WatchDetailsSection({
    required this.statuses,
    required this.now,
    required this.referenceTime,
  });

  final List<WatchStopStatus> statuses;
  final DateTime now;
  final DateTime? referenceTime;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text(
            'Area Watch Details',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          subtitle: const Text(
            'Open for pass history and stop-by-stop watch logs around you.',
          ),
          children: statuses
              .map(
                (status) => Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: _WatchStopSection(
                    status: status,
                    now: now,
                    referenceTime: referenceTime,
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _WatchStopSection extends StatelessWidget {
  const _WatchStopSection({
    required this.status,
    required this.now,
    required this.referenceTime,
  });

  final WatchStopStatus status;
  final DateTime now;
  final DateTime? referenceTime;

  String? _destinationFromDirection(String? direction) {
    if (direction == null || direction.isEmpty) {
      return null;
    }

    final lower = direction.toLowerCase();
    if (lower.contains(' towards ')) {
      return direction
          .split(RegExp(r'\s+towards\s+', caseSensitive: false))
          .last;
    }
    if (direction.contains('->')) {
      return direction.split('->').last.trim();
    }
    if (lower.contains(' to ')) {
      return direction.split(RegExp(r'\s+to\s+', caseSensitive: false)).last;
    }
    return direction;
  }

  String _arrivalDirectionLine(Arrival arrival) {
    final destination = _destinationFromDirection(arrival.direction);
    if (destination == null || destination.isEmpty) {
      return arrival.direction;
    }
    return 'Toward $destination';
  }

  String _vehicleDirectionLine(Vehicle vehicle) {
    final destination = _destinationFromDirection(vehicle.routeDirection);
    if (destination == null || destination.isEmpty) {
      return vehicle.routeDirection;
    }
    return 'Toward $destination';
  }

  List<WatchEvent> _passHistoryEvents({String? excludeId}) {
    return status.recentEvents
        .where(
          (event) =>
              event.id != excludeId &&
              (event.kind == 'observed_pass' ||
                  event.kind == 'observed_arrival' ||
                  event.kind == 'prediction_evaluated'),
        )
        .toList();
  }

  String _eventTimeLabel(BuildContext context, WatchEvent event) {
    final raw = event.happenedAt;
    if (raw == null) {
      return 'recently';
    }

    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      return 'recently';
    }

    final local = parsed.toLocal();
    final timeOfDay = TimeOfDay.fromDateTime(local);
    return MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(timeOfDay, alwaysUse24HourFormat: false);
  }

  String _passHistoryMeta(BuildContext context, WatchEvent event) {
    final parts = <String>[_eventTimeLabel(context, event)];
    if (event.currentStopDistanceM != null) {
      parts.add('${event.currentStopDistanceM}m from stop');
    }
    if (event.errorSeconds != null) {
      parts.add('miss ${event.errorSeconds}s');
    }
    return parts.join(' | ');
  }

  List<Vehicle> _unmatchedLiveVehicles() {
    final matchedVehicleIds = status.primaryArrivals
        .map((arrival) => arrival.vehicleUid)
        .whereType<int>()
        .toSet();

    return status.liveVehicles
        .where((vehicle) => !matchedVehicleIds.contains(vehicle.uid))
        .toList();
  }

  String _watchTier(Arrival arrival) {
    if (arrival.confidenceState != 'tracking') {
      return arrival.statusText;
    }
    final etaSeconds = arrival.watchEtaSeconds ?? arrival.etaSeconds;
    if (etaSeconds <= 300) {
      return '5-min watch';
    }
    if (etaSeconds <= 600) {
      return '10-min watch';
    }
    if (etaSeconds <= _comingSoonWindowSeconds) {
      return '30-min watch';
    }
    return 'Live watch';
  }

  String _accuracyText() {
    if (status.accuracySummary.evaluatedAlerts == 0) {
      return 'Still collecting truth data at this stop. First checked arrivals will show error after buses pass.';
    }

    final avg = status.accuracySummary.avgAbsErrorSeconds ?? 0;
    return '${status.accuracySummary.evaluatedAlerts} checked alert(s), average miss ${avg}s.';
  }

  String _liveVehicleTitle(Vehicle vehicle) {
    final detail = _vehicleDirectionLine(vehicle);
    if (detail.isEmpty) {
      return vehicle.routeNumber.isEmpty ? 'Tracked bus' : vehicle.routeNumber;
    }
    return vehicle.routeNumber.isEmpty
        ? detail
        : '${vehicle.routeNumber} $detail';
  }

  // ignore: unused_element
  String _liveVehicleMeta(Vehicle vehicle) {
    final distanceText = vehicle.distanceMeters == null
        ? 'Near stop'
        : '${vehicle.distanceMeters}m from stop';
    final motionText = vehicle.moving ? 'moving now' : vehicle.statusText;
    return '$distanceText â€¢ $motionText';
  }

  @override
  Widget build(BuildContext context) {
    final unmatchedLiveVehicles = _unmatchedLiveVehicles();
    final passHistory = _passHistoryEvents();
    final WatchEvent? lastPassEvent = null;

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Watch ${status.stop.name}',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Calls out tracked buses at 30, 10, and 5 minutes, then confirms close-range and pass events from live telemetry even when stop ETA feed misses.',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => context.push('/stops/${status.stop.id}'),
                icon: const Icon(Icons.location_on_outlined),
                label: const Text('Open Stop'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ToneChip(
                label: 'Refresh ${status.refreshHintSeconds}s',
                color: const Color(0xFF355C7D),
              ),
              ToneChip(
                label: '${status.primaryArrivals.length} live arrival(s)',
                color: const Color(0xFF0B7A75),
              ),
              ToneChip(
                label: '${status.announcedArrivals.length} announced later',
                color: const Color(0xFFE09F27),
              ),
              if (status.liveVehicles.isNotEmpty)
                ToneChip(
                  label: '${status.liveVehicles.length} live nearby',
                  color: const Color(0xFF6C5B7B),
                ),
            ],
          ),
          if (lastPassEvent != null) ...[
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFDECEA),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.history_toggle_off_rounded,
                    color: Color(0xFF9B1C1C),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Bus Passed Here',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        ToneChip(
                          label: _passBadgeLabel(lastPassEvent, now),
                          color: const Color(0xFF9B4D3D),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${lastPassEvent.routeNumber ?? 'Bus'} â€¢ ${_eventDirectionLine(lastPassEvent)}',
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_eventTimeLabel(context, lastPassEvent)}${lastPassEvent.currentStopDistanceM != null ? ' â€¢ ${lastPassEvent.currentStopDistanceM}m from stop' : ''}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'History only. Use this to see when last bus cleared your stop.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (passHistory.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              'Passed Already',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            ...passHistory
                .take(3)
                .map(
                  (event) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _watchEventIcon(event.kind),
                      color: _watchEventColor(event.kind),
                    ),
                    title: Text(
                      event.message,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(_passHistoryMeta(context, event)),
                  ),
                ),
          ],
          const SizedBox(height: 18),
          Text(
            'Watch Now',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (status.primaryArrivals.isEmpty)
            Text(
              unmatchedLiveVehicles.isEmpty
                  ? 'No tracked bus locked for this stop yet. Keep app open and it will alert when route becomes live.'
                  : 'Stop ETA feed not locked yet, but live telemetry already sees bus movement near this stop.',
              style: Theme.of(context).textTheme.bodyLarge,
            )
          else
            ...status.primaryArrivals
                .take(4)
                .map(
                  (arrival) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FBFB),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          RoutePill(label: arrival.routeNumber),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  arrival.routeName,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _arrivalDirectionLine(arrival),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: const Color(0xFF355C7D),
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'ETA ${formatArrivalEtaForDisplay(arrival)} â€¢ ${_watchTier(arrival)}',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                if (arrival.rawEtaLabel != null ||
                                    (arrival.predictionBiasSeconds ?? 0) != 0)
                                  Text(
                                    'Raw ${arrival.rawEtaLabel ?? arrival.etaLabel}${(arrival.predictionBiasSeconds ?? 0) != 0 ? ' â€¢ bias ${arrival.predictionBiasSeconds! > 0 ? '+' : ''}${arrival.predictionBiasSeconds}s' : ''}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          ConfidenceChip(
                            state: arrival.confidenceState,
                            label: arrival.statusText,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
          if (unmatchedLiveVehicles.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'Live Near Stop',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            ...unmatchedLiveVehicles
                .take(4)
                .map(
                  (vehicle) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FBFB),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          RoutePill(
                            label: vehicle.routeNumber.isEmpty
                                ? '?'
                                : vehicle.routeNumber,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _liveVehicleTitle(vehicle),
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _watchVehicleMetaLine(
                                    vehicle,
                                    now,
                                    referenceTime,
                                  ),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          ConfidenceChip(
                            state: vehicle.confidenceState,
                            label: vehicle.statusText,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
          ],
          const SizedBox(height: 18),
          Text(
            'Accuracy Check',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(_accuracyText(), style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ToneChip(
                label:
                    '30m avg ${status.accuracySummary.eta30m.avgAbsErrorSeconds ?? '--'}s',
                color: const Color(0xFFE09F27),
              ),
              ToneChip(
                label:
                    '5m avg ${status.accuracySummary.eta5m.avgAbsErrorSeconds ?? '--'}s',
                color: const Color(0xFF0B7A75),
              ),
              ToneChip(
                label:
                    '10m avg ${status.accuracySummary.eta10m.avgAbsErrorSeconds ?? '--'}s',
                color: const Color(0xFF355C7D),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'Recent Watch Events',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (status.recentEvents.isEmpty)
            Text(
              'No watch events yet. Leave app running and tracker will log alerts and pass history here.',
              style: Theme.of(context).textTheme.bodyLarge,
            )
          else
            ...status.recentEvents
                .take(5)
                .map(
                  (event) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _watchEventIcon(event.kind),
                      color: _watchEventColor(event.kind),
                    ),
                    title: Text(
                      event.message,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      event.routeNumber == null
                          ? event.kind
                          : '${event.routeNumber} ${event.routeName ?? ''}',
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

class _AreaRoutesSection extends StatelessWidget {
  const _AreaRoutesSection({
    required this.items,
    required this.trackedByRouteId,
    required this.now,
    required this.referenceTime,
  });

  final List<_AreaRouteMatch> items;
  final Map<String, TrackedRoute> trackedByRouteId;
  final DateTime now;
  final DateTime? referenceTime;

  String? _destinationFromDirection(String? direction) {
    if (direction == null || direction.isEmpty) {
      return null;
    }

    final lower = direction.toLowerCase();
    if (lower.contains(' towards ')) {
      return direction
          .split(RegExp(r'\s+towards\s+', caseSensitive: false))
          .last;
    }
    if (direction.contains('->')) {
      return direction.split('->').last.trim();
    }
    if (lower.contains(' to ')) {
      return direction.split(RegExp(r'\s+to\s+', caseSensitive: false)).last;
    }
    return direction;
  }

  String _directionLine(Arrival arrival) {
    final destination = _destinationFromDirection(arrival.direction);
    if (destination == null || destination.isEmpty) {
      return arrival.routeName;
    }
    return 'Toward $destination';
  }

  /// Same corridor names (e.g. Lodge School) often appear on multiple official
  /// route numbers with different departure timesâ€”not a data duplicate.
  String _serviceScheduleLine(Arrival arrival) {
    final liveLike = arrival.confidenceState == 'tracking' ||
        arrival.confidenceState == 'at_terminal';
    if (liveLike) {
      return 'Service ${arrival.routeNumber} Â· ETA ${arrival.etaLabel}';
    }
    return 'Service ${arrival.routeNumber} Â· Scheduled ${arrival.scheduledLabel}';
  }

  String _stopLine(_AreaRouteMatch item) {
    return 'Nearest stop on this route â€¢ ${item.stop.name} â€¢ ${_formatDistanceLabel(item.stopDistanceMeters)} from you';
  }

  static const int _busNearUserThresholdM = 380;

  bool _busNearUserPin(_AreaRouteMatch item) {
    final d = item.vehicle?.distanceMeters;
    return d != null && d <= _busNearUserThresholdM;
  }

  String? _busNearUserLine(_AreaRouteMatch item) {
    final d = item.vehicle?.distanceMeters;
    if (d == null || d > _busNearUserThresholdM) {
      return null;
    }
    return 'Live bus ~${_formatDistanceLabel(d)} from your location (map pin)';
  }

  TrackedRoute? _trackedRouteFor(_AreaRouteMatch item) {
    return trackedByRouteId[item.arrival.routeId];
  }

  Vehicle? _leadVehicle(_AreaRouteMatch item) {
    return _leadVehicleForAreaRoute(item, trackedByRouteId);
  }

  String _effectiveState(_AreaRouteMatch item) {
    return _effectiveAreaRouteState(item, trackedByRouteId);
  }

  String _effectiveLabel(_AreaRouteMatch item) {
    return _effectiveAreaRouteLabel(item, trackedByRouteId);
  }

  int _trackedCount(_AreaRouteMatch item) {
    return _trackedRouteFor(item)?.activeVehicles.length ??
        (item.vehicle != null ? 1 : 0);
  }

  int _movingCount(_AreaRouteMatch item) {
    final trackedRoute = _trackedRouteFor(item);
    if (trackedRoute != null) {
      return trackedRoute.activeVehicles
          .where((vehicle) => vehicle.moving)
          .length;
    }
    return item.vehicle?.moving == true ? 1 : 0;
  }



  String _routeStatusLine(_AreaRouteMatch item) {
    final leadVehicle = _leadVehicle(item);
    if (leadVehicle == null) {
      return _explicitArrivalStatusLine(item.arrival, now, referenceTime);
    }
    final seenSeconds = _liveSeenSeconds(
      baseSeconds: leadVehicle.lastSeenSeconds,
      now: now,
      referenceTime: referenceTime,
    );
    final movementLabel =
        leadVehicle.moving || leadVehicle.confidenceState == 'tracking'
        ? 'Live bus on this route now'
        : leadVehicle.statusText;
    return '$movementLabel | tap to open bus on map${seenSeconds == null ? '' : ' | ping ${seenSeconds}s ago'}';
  }

  @override
  Widget build(BuildContext context) {
    final rankedItems = [...items]
      ..sort((left, right) {
        final leftNear = _busNearUserPin(left);
        final rightNear = _busNearUserPin(right);
        if (leftNear != rightNear) {
          return leftNear ? -1 : 1;
        }

        final leftTracked = _trackedCount(left);
        final rightTracked = _trackedCount(right);
        if (leftTracked != rightTracked) {
          return rightTracked.compareTo(leftTracked);
        }

        final leftMoving = _movingCount(left);
        final rightMoving = _movingCount(right);
        if (leftMoving != rightMoving) {
          return rightMoving.compareTo(leftMoving);
        }

        final leftEta = left.arrival.watchEtaSeconds ?? left.arrival.etaSeconds;
        final rightEta =
            right.arrival.watchEtaSeconds ?? right.arrival.etaSeconds;
        if (leftEta != rightEta) {
          return leftEta.compareTo(rightEta);
        }

        final leftBus = left.vehicle?.distanceMeters ?? 1 << 30;
        final rightBus = right.vehicle?.distanceMeters ?? 1 << 30;
        if (leftBus != rightBus) {
          return leftBus.compareTo(rightBus);
        }

        return left.stopDistanceMeters.compareTo(right.stopDistanceMeters);
      });

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Routes Around You',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'â€œBus near your pinâ€ uses GPS distance to the live vehicle. â€œNearest stop on routeâ€ means a stop on that line is closeâ€”the bus may still be on another road. Rows that look alike but show different route numbers (e.g. SCH 115 vs SCH 125B) are separate timetabled runs on the same corridor, not duplicates.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            Text(
              'No route matches near you yet. Keep app open or widen radius.',
              style: Theme.of(context).textTheme.bodyLarge,
            )
          else
            SizedBox(
              height: 240, // Fixed height for horizontal cards
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: rankedItems.length > 10 ? 10 : rankedItems.length,
                separatorBuilder: (context, index) => const SizedBox(width: 16),
                itemBuilder: (context, index) {
                  final item = rankedItems[index];
                  final busNearLine = _busNearUserLine(item);
                  return InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => context.push(
                      _routePath(
                        item.arrival.routeId,
                        vehicleUid: _leadVehicle(item)?.uid,
                      ),
                    ),
                    child: Container(
                      width: MediaQuery.of(context).size.width * 0.8, // 80% width for peeking
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _effectiveState(item) == 'tracking' ||
                                _effectiveState(item) == 'at_terminal'
                            ? const Color(0xFF002845) // Slightly brighter navy for live routes
                            : const Color(0xFF001F3F), // Dark navy for scheduled routes
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(0xFF00E5FF).withValues(alpha: 0.1),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              RoutePill(label: item.arrival.routeNumber),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _directionLine(item.arrival),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      item.arrival.routeName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.bodyMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _serviceScheduleLine(item.arrival),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w800,
                                            color: const Color(0xFF00E5FF),
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              ConfidenceChip(
                                state: _effectiveState(item),
                                label: _effectiveLabel(item),
                              ),
                            ],
                          ),
                          const Spacer(),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                if (_trackedCount(item) > 0) ...[
                                  ToneChip(
                                    label: '${_trackedCount(item)} tracked now',
                                    color: const Color(0xFF00E5FF),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                if (busNearLine != null) ...[
                                  ToneChip(
                                    label: busNearLine,
                                    color: const Color(0xFF00E5FF),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                ToneChip(
                                  label: _stopLine(item),
                                  color: Colors.white.withValues(alpha: 0.15),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _routeStatusLine(item),
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _NearbyStopsSection extends StatelessWidget {
  const _NearbyStopsSection({
    required this.liveStops,
    required this.announcedStops,
    required this.now,
    required this.referenceTime,
  });

  final List<NearbyStop> liveStops;
  final List<NearbyStop> announcedStops;
  final DateTime now;
  final DateTime? referenceTime;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text(
            'Stop-by-stop View',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          subtitle: const Text(
            'Open only if you want every nearby stop broken out separately.',
          ),
          children: [
            if (liveStops.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ArrivalSection(
                title: 'Live now',
                subtitle:
                    'Nearby stops with buses tracking or waiting at terminal right now.',
                stops: liveStops,
                selectArrivals: (stop) => stop.primaryArrivals,
                now: now,
                referenceTime: referenceTime,
              ),
            ],
            if (announcedStops.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ArrivalSection(
                title: 'Announced later',
                subtitle: 'Schedule-only or not-yet-departed services nearby.',
                stops: announcedStops,
                selectArrivals: (stop) => stop.announcedArrivals,
                now: now,
                referenceTime: referenceTime,
              ),
            ],
            if (liveStops.isEmpty && announcedStops.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'No nearby stop groups yet.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ExploreMoreSection extends StatelessWidget {
  final TrackedRoutesResponse? tracked;
  final List<_RouteFocusMatch> routeMatches;
  final List<_StopFocusMatch> stopMatches;
  final SavedLocation? location;

  const _ExploreMoreSection({
    required this.tracked,
    required this.routeMatches,
    required this.stopMatches,
    this.location,
  });

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text(
            'See More Routes',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          subtitle: const Text(
            'Island-wide tracking and wider corridor groups live here when you want to branch out.',
          ),
          children: [
            if (tracked != null) ...[
              const SizedBox(height: 12),
              _TrackedIslandSection(tracked: tracked!, location: location),
            ],
            if (routeMatches.isNotEmpty || stopMatches.isNotEmpty) ...[
              const SizedBox(height: 12),
              _FocusSection(
                routeMatches: routeMatches,
                stopMatches: stopMatches,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TrackedIslandSection extends StatelessWidget {
  const _TrackedIslandSection({required this.tracked, this.location});

  final TrackedRoutesResponse tracked;
  final SavedLocation? location;

  @override
  Widget build(BuildContext context) {
    final routeVehicles = tracked.routes
        .expand(
          (route) => route.activeVehicles.map(
            (vehicle) => _TrackedVehicleEntry(route: route, vehicle: vehicle),
          ),
        )
        .toList();

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tracked Now Across Island',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            '${tracked.vehicleCount} buses tied to live tracking right now. Tap marker or route row to open that corridor from island view.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 260,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: FlutterMap(
                options: MapOptions(
                  initialCenter: location != null ? LatLng(location!.lat, location!.lng) : _defaultIslandCenter,
                  initialZoom: location != null ? 12.0 : 10.8,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'barbados_bus_demo',
                  ),
                  PolylineLayer(
                    polylines: routeVehicles
                        .where(
                          (entry) => entry.vehicle.previousPosition != null,
                        )
                        .map(
                          (entry) => Polyline(
                            points: [
                              LatLng(
                                entry.vehicle.previousPosition!.lat,
                                entry.vehicle.previousPosition!.lng,
                              ),
                              LatLng(
                                entry.vehicle.position.lat,
                                entry.vehicle.position.lng,
                              ),
                            ],
                            strokeWidth: 3,
                            color: confidenceColor(
                              entry.vehicle.confidenceState,
                            ).withValues(alpha: 0.35),
                          ),
                        )
                        .toList(),
                  ),
                  MarkerLayer(
                    markers: routeVehicles
                        .map(
                          (entry) => Marker(
                            point: LatLng(
                              entry.vehicle.position.lat,
                              entry.vehicle.position.lng,
                            ),
                            width: 78,
                            height: 78,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => context.push(
                                '/routes/${entry.route.id}?vehicle=${entry.vehicle.uid}',
                              ),
                              child: BusPulseMarker(
                                state: entry.vehicle.confidenceState,
                                routeLabel: entry.vehicle.routeNumber,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  if (location != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: LatLng(location!.lat, location!.lng),
                          width: 44,
                          height: 44,
                          child: const UserLocationMarker(),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          ...tracked.routes
              .take(10)
              .map(
                (route) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${route.routeNumber} ${route.routeName}'.trim(),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    route.activeVehicles.isEmpty
                        ? route.topStatusText ?? 'No live unit'
                        : '${route.topStatusText ?? route.topState ?? 'tracking'} - ${route.activeVehicles.length} live unit(s)',
                  ),
                  trailing: ConfidenceChip(
                    state: route.topState ?? 'tracking',
                    label: route.topStatusText ?? route.topState ?? 'Tracking',
                  ),
                  onTap: () => context.push(
                    _routePath(
                      route.id,
                      vehicleUid: route.activeVehicles.isEmpty
                          ? null
                          : route.activeVehicles.first.uid,
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _FocusSection extends StatelessWidget {
  const _FocusSection({required this.routeMatches, required this.stopMatches});

  final List<_RouteFocusMatch> routeMatches;
  final List<_StopFocusMatch> stopMatches;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Route Radar',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'Bridgetown, Warrens, Sam Lord\'s, College Savannah, Oistins, and Six Roads ranked against where you are now. Live buses float to top; duplicate official route rows are collapsed by id, and direction is shown when names look alike.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          if (routeMatches.isNotEmpty) ...[
            const SizedBox(height: 16),
            ...routeMatches.map(
              (match) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _FocusRouteCard(match: match),
              ),
            ),
          ],
          if (stopMatches.isNotEmpty) ...[
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: stopMatches
                  .map(
                    (match) => ActionChip(
                      label: Text(
                        match.distanceMeters == null
                            ? match.label
                            : '${match.label} â€¢ ${_formatDistanceLabel(match.distanceMeters!)}',
                      ),
                      avatar: const Icon(Icons.location_on_outlined, size: 18),
                      onPressed: () => context.push('/stops/${match.stop.id}'),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _FocusRouteCard extends StatelessWidget {
  const _FocusRouteCard({required this.match});

  final _RouteFocusMatch match;

  String _routeMeta(_RouteFocusOption option) {
    final parts = <String>[];
    if (option.tracked != null) {
      parts.add('${option.tracked!.activeVehicles.length} live now');
    }
    if (option.closestStop != null) {
      final stopLabel = option.closestStop!.inNearbyArea
          ? 'near ${option.closestStop!.stop.name}'
          : 'closest stop ${option.closestStop!.stop.name}';
      parts.add(
        '$stopLabel â€¢ ${_formatDistanceLabel(option.closestStop!.distanceMeters)}',
      );
    } else {
      parts.add('${option.route.from} -> ${option.route.to}');
    }
    return parts.join(' | ');
  }

  @override
  Widget build(BuildContext context) {
    final liveVehicleCount = match.options.fold<int>(
      0,
      (sum, option) => sum + (option.tracked?.activeVehicles.length ?? 0),
    );
    final nearbyCount = match.options
        .where((option) => option.closestStop?.inNearbyArea == true)
        .length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FBFB),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      match.label,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      liveVehicleCount > 0
                          ? '$liveVehicleCount live bus(es) across ${match.options.length} route match(es)'
                          : '${match.options.length} route match(es) ready to watch',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ToneChip(
                    label: liveVehicleCount > 0
                        ? '$liveVehicleCount live'
                        : 'No live bus',
                    color: liveVehicleCount > 0
                        ? const Color(0xFF0B7A75)
                        : const Color(0xFFE09F27),
                  ),
                  if (nearbyCount > 0) ...[
                    const SizedBox(height: 8),
                    ToneChip(
                      label: '$nearbyCount close by',
                      color: const Color(0xFF355C7D),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...match.options
              .take(4)
              .map(
                (option) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => context.push(
                      _routePath(
                        option.route.id,
                        vehicleUid:
                            option.tracked == null ||
                                option.tracked!.activeVehicles.isEmpty
                            ? null
                            : option.tracked!.activeVehicles.first.uid,
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE5ECEB)),
                      ),
                      child: Row(
                        children: [
                          RoutePill(label: option.route.routeNumber),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  option.route.routeName,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                if (option.route.from.trim().isNotEmpty &&
                                    option.route.to.trim().isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    '${option.route.from} â†’ ${option.route.to}',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                                const SizedBox(height: 2),
                                Text(
                                  _routeMeta(option),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          option.tracked != null
                              ? ConfidenceChip(
                                  state: option.tracked!.topState ?? 'tracking',
                                  label:
                                      '${option.tracked!.activeVehicles.length} live',
                                )
                              : ToneChip(
                                  label: option.closestStop == null
                                      ? 'Route only'
                                      : _formatDistanceLabel(
                                          option.closestStop!.distanceMeters,
                                        ),
                                  color:
                                      option.closestStop?.inNearbyArea == true
                                      ? const Color(0xFF355C7D)
                                      : const Color(0xFFE09F27),
                                ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _ArrivalSection extends StatelessWidget {
  const _ArrivalSection({
    required this.title,
    required this.subtitle,
    required this.stops,
    required this.selectArrivals,
    required this.now,
    required this.referenceTime,
  });

  final String title;
  final String subtitle;
  final List<NearbyStop> stops;
  final List<Arrival> Function(NearbyStop stop) selectArrivals;
  final DateTime now;
  final DateTime? referenceTime;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(subtitle, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 14),
          if (stops.isEmpty)
            Text(
              title == 'Live now'
                  ? 'No confirmed live buses nearby yet.'
                  : 'No low-certainty announcements in this area right now.',
              style: Theme.of(context).textTheme.bodyLarge,
            )
          else
            ...stops.map(
              (stop) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _StopArrivalCard(
                  stop: stop,
                  arrivals: selectArrivals(stop),
                  now: now,
                  referenceTime: referenceTime,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StopArrivalCard extends StatelessWidget {
  const _StopArrivalCard({
    required this.stop,
    required this.arrivals,
    required this.now,
    required this.referenceTime,
  });

  final NearbyStop stop;
  final List<Arrival> arrivals;
  final DateTime now;
  final DateTime? referenceTime;

  // ignore: unused_element
  String _arrivalLabel(Arrival arrival) {
    switch (arrival.confidenceState) {
      case 'tracking':
        return 'ETA ${formatArrivalEtaForDisplay(arrival)}';
      case 'at_terminal':
        return 'At terminal â€¢ scheduled ${arrival.scheduledLabel}';
      case 'stale':
        return arrival.statusText;
      default:
        return 'Scheduled after ${arrival.scheduledLabel}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => context.push('/stops/${stop.stop.id}'),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FBFB),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stop.stop.name,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        stop.stop.description.isEmpty
                            ? '${stop.stop.routes.length} routes serve this stop'
                            : stop.stop.description,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                ToneChip(
                  label: '${stop.distanceMeters}m',
                  color: const Color(0xFFE09F27),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ...arrivals.map(
              (arrival) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    RoutePill(label: arrival.routeNumber),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            arrival.routeName,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _explicitArrivalStatusLine(
                              arrival,
                              now,
                              referenceTime,
                            ),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    ConfidenceChip(
                      state: arrival.confidenceState,
                      label: arrival.statusText,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WatchIncomingArrival {
  const _WatchIncomingArrival({
    required this.status,
    required this.arrival,
    this.latestEvent,
  });

  final WatchStopStatus status;
  final Arrival arrival;
  final WatchEvent? latestEvent;
}

class _AreaAlertEntry {
  const _AreaAlertEntry({required this.status, required this.event});

  final WatchStopStatus status;
  final WatchEvent event;
}

class _FocusQuery {
  _FocusQuery({required this.label, String? keyword, List<String>? keywords})
    : keywords = keywords ?? (keyword == null ? const [] : [keyword]);

  final String label;
  final List<String> keywords;
}

class _ProximityPing {
  const _ProximityPing({
    required this.uid,
    required this.routeLabel,
    required this.distanceMeters,
  });

  final int uid;
  final String routeLabel;
  final int distanceMeters;
}

class _TrackedVehicleEntry {
  const _TrackedVehicleEntry({required this.route, required this.vehicle});

  final TrackedRoute route;
  final Vehicle vehicle;
}

class _TrackedAreaVehicle {
  const _TrackedAreaVehicle({
    required this.route,
    required this.vehicle,
    required this.stop,
    required this.stopDistanceMeters,
  });

  final TrackedRoute route;
  final Vehicle vehicle;
  final StopSummary stop;
  final int stopDistanceMeters;
}

class _AreaRouteMatch {
  const _AreaRouteMatch({
    required this.stop,
    required this.stopDistanceMeters,
    required this.arrival,
    this.vehicle,
  });

  final StopSummary stop;
  final int stopDistanceMeters;
  final Arrival arrival;
  final Vehicle? vehicle;
}

class _StopDistanceMatch {
  const _StopDistanceMatch({
    required this.stop,
    required this.distanceMeters,
    required this.inNearbyArea,
  });

  final StopSummary stop;
  final int distanceMeters;
  final bool inNearbyArea;
}

class _RouteFocusOption {
  const _RouteFocusOption({
    required this.route,
    this.tracked,
    this.closestStop,
  });

  final RouteSummary route;
  final TrackedRoute? tracked;
  final _StopDistanceMatch? closestStop;
}

class _RouteFocusMatch {
  const _RouteFocusMatch({required this.label, required this.options});

  final String label;
  final List<_RouteFocusOption> options;
}

class _StopFocusMatch {
  const _StopFocusMatch({
    required this.label,
    required this.stop,
    this.distanceMeters,
  });

  final String label;
  final StopSummary stop;
  final int? distanceMeters;
}

class _LiveEtaHero extends StatelessWidget {
  const _LiveEtaHero({
    required this.locationStatus,
    required this.radius,
    required this.trackedCount,
    required this.notificationLabel,
  });

  final LocationStatus locationStatus;
  final int radius;
  final int trackedCount;
  final String notificationLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: Color(0xFF00E5FF),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: Color(0x6600E5FF), blurRadius: 8),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'LIVE ETA',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: const Color(0xFF00E5FF),
                  letterSpacing: 2,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Transit Pulse',
            style: Theme.of(context).textTheme.displayMedium,
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ToneChip(
                  label: 'Radius ${radius}m',
                  color: const Color(0xFF00E5FF),
                ),
                const SizedBox(width: 8),
                ToneChip(
                  label: locationStatus == LocationStatus.available
                      ? 'Local live'
                      : 'GPS standby',
                  color: locationStatus == LocationStatus.available
                      ? const Color(0xFF00E5FF)
                      : const Color(0xFFB45309),
                ),
                const SizedBox(width: 8),
                ToneChip(
                  label: '$trackedCount live islandwide',
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                ToneChip(
                  label: notificationLabel,
                  color: const Color(0xFF00E5FF),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationWaitCard extends StatelessWidget {
  const _LocationWaitCard();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Syncing coordinates...',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            'We are finding the closest stops to your position. Tracked routes above remain live regardless of GPS status.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.6),
                ),
          ),
        ],
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        width: 36,
        height: 5,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.20),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}


