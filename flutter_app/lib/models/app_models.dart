class RouteSummary {
  RouteSummary({
    required this.id,
    required this.routeNumber,
    required this.routeName,
    required this.from,
    required this.to,
    required this.source,
    required this.hasLiveRoute,
    this.busId,
    this.liveRouteId,
  });

  factory RouteSummary.fromJson(Map<String, dynamic> json) {
    return RouteSummary(
      id: '${json['id']}',
      routeNumber: '${json['route_number'] ?? ''}',
      routeName: '${json['route_name'] ?? ''}',
      from: '${json['from'] ?? ''}',
      to: '${json['to'] ?? ''}',
      source: '${json['source'] ?? 'official'}',
      hasLiveRoute: json['has_live_route'] == true,
      busId: _asInt(json['bus_id']),
      liveRouteId: _asInt(json['live_route_id']),
    );
  }

  final String id;
  final String routeNumber;
  final String routeName;
  final String from;
  final String to;
  final String source;
  final bool hasLiveRoute;
  final int? busId;
  final int? liveRouteId;
}

class StopSummary {
  StopSummary({
    required this.id,
    required this.name,
    required this.description,
    required this.lat,
    required this.lng,
    required this.routes,
  });

  factory StopSummary.fromJson(Map<String, dynamic> json) {
    return StopSummary(
      id: _asInt(json['id']) ?? 0,
      name: '${json['name'] ?? ''}',
      description: '${json['description'] ?? ''}',
      lat: _asDouble(json['lat']) ?? 0,
      lng: _asDouble(json['lng']) ?? 0,
      routes: (json['routes'] as List<dynamic>? ?? [])
          .map((item) => RouteSummary.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  final int id;
  final String name;
  final String description;
  final double lat;
  final double lng;
  final List<RouteSummary> routes;
}

class ConfidenceSummary {
  ConfidenceSummary({
    required this.tracking,
    required this.atTerminal,
    required this.announced,
    required this.stale,
  });

  factory ConfidenceSummary.fromJson(Map<String, dynamic> json) {
    return ConfidenceSummary(
      tracking: _asInt(json['tracking']) ?? 0,
      atTerminal: _asInt(json['at_terminal']) ?? 0,
      announced: _asInt(json['announced']) ?? 0,
      stale: _asInt(json['stale']) ?? 0,
    );
  }

  final int tracking;
  final int atTerminal;
  final int announced;
  final int stale;
}

class Arrival {
  Arrival({
    required this.routeId,
    required this.routeNumber,
    required this.routeName,
    required this.direction,
    required this.etaSeconds,
    required this.etaLabel,
    required this.etaType,
    required this.scheduledLabel,
    required this.delaySeconds,
    required this.vehicleUid,
    required this.freshness,
    required this.routeSource,
    required this.confidenceState,
    required this.confidenceScore,
    required this.statusText,
    required this.liveTracking,
    required this.movementM90s,
    required this.progressDelta90s,
    this.scheduledTime,
    this.lastSeenSeconds,
    this.originDistanceM,
    this.busId,
    this.liveRouteId,
    this.watchEtaSeconds,
    this.watchEtaLabel,
    this.rawEtaLabel,
    this.predictionBiasSeconds,
    this.predictionSampleCount,
  });

  factory Arrival.fromJson(Map<String, dynamic> json) {
    return Arrival(
      routeId: '${json['route_id']}',
      routeNumber: '${json['route_number'] ?? ''}',
      routeName: '${json['route_name'] ?? ''}',
      direction: '${json['direction'] ?? ''}',
      etaSeconds: _asInt(json['eta_seconds']) ?? 0,
      etaLabel: '${json['eta_label'] ?? ''}',
      etaType: '${json['eta_type'] ?? 'schedule'}',
      scheduledTime: json['scheduled_time']?.toString(),
      scheduledLabel: '${json['scheduled_label'] ?? ''}',
      delaySeconds: _asInt(json['delay_seconds']) ?? 0,
      vehicleUid: _asInt(json['vehicle_uid']),
      freshness: '${json['freshness'] ?? 'schedule'}',
      routeSource: '${json['route_source'] ?? 'official'}',
      confidenceState: '${json['confidence_state'] ?? 'announced'}',
      confidenceScore: _asDouble(json['confidence_score']) ?? 0,
      statusText: '${json['status_text'] ?? ''}',
      liveTracking: json['live_tracking'] == true,
      lastSeenSeconds: _asInt(json['last_seen_seconds']),
      originDistanceM: _asInt(json['origin_distance_m']),
      movementM90s: _asInt(json['movement_m_90s']) ?? 0,
      progressDelta90s: _asDouble(json['progress_delta_90s']) ?? 0,
      busId: _asInt(json['bus_id']),
      liveRouteId: _asInt(json['live_route_id']),
      watchEtaSeconds: _asInt(json['watch_eta_seconds']),
      watchEtaLabel: json['watch_eta_label']?.toString(),
      rawEtaLabel: json['raw_eta_label']?.toString(),
      predictionBiasSeconds: _asInt(json['prediction_bias_seconds']),
      predictionSampleCount: _asInt(json['prediction_sample_count']),
    );
  }

  final String routeId;
  final String routeNumber;
  final String routeName;
  final String direction;
  final int etaSeconds;
  final String etaLabel;
  final String etaType;
  final String? scheduledTime;
  final String scheduledLabel;
  final int delaySeconds;
  final int? vehicleUid;
  final String freshness;
  final String routeSource;
  final String confidenceState;
  final double confidenceScore;
  final String statusText;
  final bool liveTracking;
  final int? lastSeenSeconds;
  final int? originDistanceM;
  final int movementM90s;
  final double progressDelta90s;
  final int? busId;
  final int? liveRouteId;
  final int? watchEtaSeconds;
  final String? watchEtaLabel;
  final String? rawEtaLabel;
  final int? predictionBiasSeconds;
  final int? predictionSampleCount;

  bool get isPrimary =>
      confidenceState == 'tracking' || confidenceState == 'at_terminal';
}

class GeoPoint {
  GeoPoint({required this.lat, required this.lng, this.speedKph, this.heading});

  factory GeoPoint.fromJson(Map<String, dynamic> json) {
    return GeoPoint(
      lat: _asDouble(json['lat']) ?? 0,
      lng: _asDouble(json['lng']) ?? 0,
      speedKph: _asDouble(json['speed_kph']),
      heading: _asDouble(json['heading']),
    );
  }

  final double lat;
  final double lng;
  final double? speedKph;
  final double? heading;
}

class Vehicle {
  Vehicle({
    required this.uid,
    required this.routeId,
    required this.routeNumber,
    required this.routeDirection,
    required this.delaySeconds,
    required this.ageSeconds,
    required this.fresh,
    required this.confidenceState,
    required this.confidenceScore,
    required this.statusText,
    required this.liveTracking,
    required this.moving,
    required this.movementM90s,
    required this.progressDelta90s,
    required this.position,
    this.tripScheduleId,
    this.derivedRouteName,
    this.originDistanceM,
    this.lastSeenSeconds,
    this.distanceMeters,
    this.previousPosition,
  });

  factory Vehicle.fromJson(Map<String, dynamic> json) {
    return Vehicle(
      uid: _asInt(json['uid']) ?? 0,
      routeId: _asInt(json['route_id']) ?? 0,
      routeNumber: '${json['route_number'] ?? ''}',
      routeDirection: '${json['route_direction'] ?? ''}',
      tripScheduleId: _asInt(json['trip_schedule_id']),
      derivedRouteName: json['derived_route_name']?.toString(),
      delaySeconds: _asInt(json['delay_seconds']) ?? 0,
      ageSeconds: _asInt(json['age_seconds']) ?? 0,
      fresh: json['fresh'] == true,
      confidenceState: '${json['confidence_state'] ?? 'stale'}',
      confidenceScore: _asDouble(json['confidence_score']) ?? 0,
      statusText: '${json['status_text'] ?? ''}',
      liveTracking: json['live_tracking'] == true,
      moving: json['moving'] == true,
      movementM90s: _asInt(json['movement_m_90s']) ?? 0,
      progressDelta90s: _asDouble(json['progress_delta_90s']) ?? 0,
      originDistanceM: _asInt(json['origin_distance_m']),
      lastSeenSeconds: _asInt(json['last_seen_seconds']),
      distanceMeters: _asInt(json['distance_m']),
      position: GeoPoint.fromJson(
        (json['position'] as Map<String, dynamic>? ?? const {}),
      ),
      previousPosition: json['previous_position'] is Map<String, dynamic>
          ? GeoPoint.fromJson(json['previous_position'] as Map<String, dynamic>)
          : null,
    );
  }

  final int uid;
  final int routeId;
  final String routeNumber;
  final String routeDirection;
  final int? tripScheduleId;
  final String? derivedRouteName;
  final int delaySeconds;
  final int ageSeconds;
  final bool fresh;
  final String confidenceState;
  final double confidenceScore;
  final String statusText;
  final bool liveTracking;
  final bool moving;
  final int movementM90s;
  final double progressDelta90s;
  final int? originDistanceM;
  final int? lastSeenSeconds;
  final int? distanceMeters;
  final GeoPoint position;
  final GeoPoint? previousPosition;
}

class NearbyStop {
  NearbyStop({
    required this.stop,
    required this.distanceMeters,
    required this.arrivals,
    required this.primaryArrivals,
    required this.announcedArrivals,
    required this.staleArrivals,
    required this.confidenceSummary,
  });

  factory NearbyStop.fromJson(Map<String, dynamic> json) {
    return NearbyStop(
      stop: StopSummary.fromJson(json['stop'] as Map<String, dynamic>),
      distanceMeters: _asInt(json['distance_m']) ?? 0,
      arrivals: (json['arrivals'] as List<dynamic>? ?? [])
          .map((item) => Arrival.fromJson(item as Map<String, dynamic>))
          .toList(),
      primaryArrivals: (json['primary_arrivals'] as List<dynamic>? ?? [])
          .map((item) => Arrival.fromJson(item as Map<String, dynamic>))
          .toList(),
      announcedArrivals: (json['announced_arrivals'] as List<dynamic>? ?? [])
          .map((item) => Arrival.fromJson(item as Map<String, dynamic>))
          .toList(),
      staleArrivals: (json['stale_arrivals'] as List<dynamic>? ?? [])
          .map((item) => Arrival.fromJson(item as Map<String, dynamic>))
          .toList(),
      confidenceSummary: ConfidenceSummary.fromJson(
        json['confidence_summary'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }

  final StopSummary stop;
  final int distanceMeters;
  final List<Arrival> arrivals;
  final List<Arrival> primaryArrivals;
  final List<Arrival> announcedArrivals;
  final List<Arrival> staleArrivals;
  final ConfidenceSummary confidenceSummary;
}

class NearbyResponse {
  NearbyResponse({
    required this.nearbyStops,
    required this.radiusMeters,
    required this.nearbyVehicles,
    required this.refreshHintSeconds,
  });

  factory NearbyResponse.fromJson(Map<String, dynamic> json) {
    return NearbyResponse(
      nearbyStops: (json['stops'] as List<dynamic>? ?? [])
          .map((item) => NearbyStop.fromJson(item as Map<String, dynamic>))
          .toList(),
      radiusMeters: _asInt(json['radius_m']) ?? 800,
      nearbyVehicles: (json['nearby_vehicles'] as List<dynamic>? ?? [])
          .map((item) => Vehicle.fromJson(item as Map<String, dynamic>))
          .toList(),
      refreshHintSeconds: _asInt(json['refresh_hint_seconds']) ?? 20,
    );
  }

  final List<NearbyStop> nearbyStops;
  final int radiusMeters;
  final List<Vehicle> nearbyVehicles;
  final int refreshHintSeconds;
}

class StopDetail {
  StopDetail({
    required this.stop,
    required this.arrivals,
    required this.primaryArrivals,
    required this.announcedArrivals,
    required this.staleArrivals,
    required this.confidenceSummary,
    required this.refreshHintSeconds,
  });

  factory StopDetail.fromJson(Map<String, dynamic> json) {
    return StopDetail(
      stop: StopSummary.fromJson(json),
      arrivals: (json['arrivals'] as List<dynamic>? ?? [])
          .map((item) => Arrival.fromJson(item as Map<String, dynamic>))
          .toList(),
      primaryArrivals: (json['primary_arrivals'] as List<dynamic>? ?? [])
          .map((item) => Arrival.fromJson(item as Map<String, dynamic>))
          .toList(),
      announcedArrivals: (json['announced_arrivals'] as List<dynamic>? ?? [])
          .map((item) => Arrival.fromJson(item as Map<String, dynamic>))
          .toList(),
      staleArrivals: (json['stale_arrivals'] as List<dynamic>? ?? [])
          .map((item) => Arrival.fromJson(item as Map<String, dynamic>))
          .toList(),
      confidenceSummary: ConfidenceSummary.fromJson(
        json['confidence_summary'] as Map<String, dynamic>? ?? const {},
      ),
      refreshHintSeconds: _asInt(json['refresh_hint_seconds']) ?? 20,
    );
  }

  final StopSummary stop;
  final List<Arrival> arrivals;
  final List<Arrival> primaryArrivals;
  final List<Arrival> announcedArrivals;
  final List<Arrival> staleArrivals;
  final ConfidenceSummary confidenceSummary;
  final int refreshHintSeconds;
}

class RouteStop {
  RouteStop({
    required this.index,
    required this.id,
    required this.name,
    required this.description,
    required this.lat,
    required this.lng,
  });

  factory RouteStop.fromJson(Map<String, dynamic> json) {
    return RouteStop(
      index: _asInt(json['index']) ?? 0,
      id: _asInt(json['id']) ?? 0,
      name: '${json['name'] ?? ''}',
      description: '${json['description'] ?? ''}',
      lat: _asDouble(json['lat']) ?? 0,
      lng: _asDouble(json['lng']) ?? 0,
    );
  }

  final int index;
  final int id;
  final String name;
  final String description;
  final double lat;
  final double lng;
}

class RouteDetail {
  RouteDetail({
    required this.id,
    required this.routeNumber,
    required this.routeName,
    required this.from,
    required this.to,
    required this.direction,
    required this.source,
    required this.description,
    required this.specialNotes,
    required this.schedules,
    required this.stops,
    required this.polyline,
    required this.activeVehicles,
    required this.refreshHintSeconds,
    this.busId,
    this.liveRouteId,
    this.liveRouteUrl,
  });

  factory RouteDetail.fromJson(Map<String, dynamic> json) {
    return RouteDetail(
      id: '${json['id']}',
      routeNumber: '${json['route_number'] ?? ''}',
      routeName: '${json['route_name'] ?? ''}',
      from: '${json['from'] ?? ''}',
      to: '${json['to'] ?? ''}',
      direction: '${json['direction'] ?? ''}',
      source: '${json['source'] ?? 'official'}',
      description: '${json['description'] ?? ''}',
      specialNotes: '${json['special_notes'] ?? ''}',
      schedules: (json['schedules'] as Map<String, dynamic>? ?? {}).map(
        (key, value) => MapEntry(
          key,
          (value as List<dynamic>? ?? []).map((item) => '$item').toList(),
        ),
      ),
      stops: (json['stops'] as List<dynamic>? ?? [])
          .map((item) => RouteStop.fromJson(item as Map<String, dynamic>))
          .toList(),
      polyline: (json['polyline'] as List<dynamic>? ?? [])
          .map((item) => GeoPoint.fromJson(item as Map<String, dynamic>))
          .toList(),
      activeVehicles: (json['active_vehicles'] as List<dynamic>? ?? [])
          .map((item) => Vehicle.fromJson(item as Map<String, dynamic>))
          .toList(),
      refreshHintSeconds: _asInt(json['refresh_hint_seconds']) ?? 20,
      busId: _asInt(json['bus_id']),
      liveRouteId: _asInt(json['live_route_id']),
      liveRouteUrl: json['live_route_url']?.toString(),
    );
  }

  final String id;
  final String routeNumber;
  final String routeName;
  final String from;
  final String to;
  final String direction;
  final String source;
  final String description;
  final String specialNotes;
  final Map<String, List<String>> schedules;
  final List<RouteStop> stops;
  final List<GeoPoint> polyline;
  final List<Vehicle> activeVehicles;
  final int refreshHintSeconds;
  final int? busId;
  final int? liveRouteId;
  final String? liveRouteUrl;
}

class TrackedRoute {
  TrackedRoute({
    required this.id,
    required this.routeNumber,
    required this.routeName,
    required this.from,
    required this.to,
    required this.source,
    required this.direction,
    required this.trackingCount,
    required this.atTerminalCount,
    required this.totalVehicles,
    required this.activeVehicles,
    this.busId,
    this.liveRouteId,
    this.topState,
    this.topStatusText,
  });

  factory TrackedRoute.fromJson(Map<String, dynamic> json) {
    return TrackedRoute(
      id: '${json['id']}',
      routeNumber: '${json['route_number'] ?? ''}',
      routeName: '${json['route_name'] ?? ''}',
      from: '${json['from'] ?? ''}',
      to: '${json['to'] ?? ''}',
      source: '${json['source'] ?? 'official'}',
      direction: '${json['direction'] ?? ''}',
      trackingCount: _asInt(json['tracking_count']) ?? 0,
      atTerminalCount: _asInt(json['at_terminal_count']) ?? 0,
      totalVehicles: _asInt(json['total_vehicles']) ?? 0,
      activeVehicles: (json['active_vehicles'] as List<dynamic>? ?? [])
          .map((item) => Vehicle.fromJson(item as Map<String, dynamic>))
          .toList(),
      busId: _asInt(json['bus_id']),
      liveRouteId: _asInt(json['live_route_id']),
      topState: json['top_state']?.toString(),
      topStatusText: json['top_status_text']?.toString(),
    );
  }

  final String id;
  final String routeNumber;
  final String routeName;
  final String from;
  final String to;
  final String source;
  final String direction;
  final int trackingCount;
  final int atTerminalCount;
  final int totalVehicles;
  final List<Vehicle> activeVehicles;
  final int? busId;
  final int? liveRouteId;
  final String? topState;
  final String? topStatusText;
}

class TrackedRoutesResponse {
  TrackedRoutesResponse({
    required this.routeCount,
    required this.vehicleCount,
    required this.refreshHintSeconds,
    required this.routes,
  });

  factory TrackedRoutesResponse.fromJson(Map<String, dynamic> json) {
    return TrackedRoutesResponse(
      routeCount: _asInt(json['route_count']) ?? 0,
      vehicleCount: _asInt(json['vehicle_count']) ?? 0,
      refreshHintSeconds: _asInt(json['refresh_hint_seconds']) ?? 20,
      routes: (json['routes'] as List<dynamic>? ?? [])
          .map((item) => TrackedRoute.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  final int routeCount;
  final int vehicleCount;
  final int refreshHintSeconds;
  final List<TrackedRoute> routes;
}

class WatchEvent {
  WatchEvent({
    required this.id,
    required this.kind,
    required this.message,
    this.happenedAt,
    this.stopId,
    this.stopName,
    this.routeId,
    this.routeNumber,
    this.routeName,
    this.routeDirection,
    this.originName,
    this.destinationName,
    this.vehicleUid,
    this.etaSeconds,
    this.predictedArrivalAt,
    this.observedArrivalAt,
    this.errorSeconds,
    this.currentStopDistanceM,
    this.upstreamStopId,
    this.upstreamStopName,
  });

  factory WatchEvent.fromJson(Map<String, dynamic> json) {
    return WatchEvent(
      id: '${json['id']}',
      kind: '${json['kind'] ?? ''}',
      message: '${json['message'] ?? ''}',
      happenedAt: json['happened_at']?.toString(),
      stopId: _asInt(json['stop_id']),
      stopName: json['stop_name']?.toString(),
      routeId: json['route_id']?.toString(),
      routeNumber: json['route_number']?.toString(),
      routeName: json['route_name']?.toString(),
      routeDirection: json['route_direction']?.toString(),
      originName: json['origin_name']?.toString(),
      destinationName: json['destination_name']?.toString(),
      vehicleUid: _asInt(json['vehicle_uid']),
      etaSeconds: _asInt(json['eta_seconds']),
      predictedArrivalAt: json['predicted_arrival_at']?.toString(),
      observedArrivalAt: json['observed_arrival_at']?.toString(),
      errorSeconds: _asInt(json['error_seconds']),
      currentStopDistanceM: _asInt(json['current_stop_distance_m']),
      upstreamStopId: _asInt(json['upstream_stop_id']),
      upstreamStopName: json['upstream_stop_name']?.toString(),
    );
  }

  final String id;
  final String kind;
  final String message;
  final String? happenedAt;
  final int? stopId;
  final String? stopName;
  final String? routeId;
  final String? routeNumber;
  final String? routeName;
  final String? routeDirection;
  final String? originName;
  final String? destinationName;
  final int? vehicleUid;
  final int? etaSeconds;
  final String? predictedArrivalAt;
  final String? observedArrivalAt;
  final int? errorSeconds;
  final int? currentStopDistanceM;
  final int? upstreamStopId;
  final String? upstreamStopName;
}

class WatchAccuracyBucket {
  WatchAccuracyBucket({
    required this.total,
    required this.evaluated,
    this.avgAbsErrorSeconds,
  });

  factory WatchAccuracyBucket.fromJson(Map<String, dynamic> json) {
    return WatchAccuracyBucket(
      total: _asInt(json['total']) ?? 0,
      evaluated: _asInt(json['evaluated']) ?? 0,
      avgAbsErrorSeconds: _asInt(json['avg_abs_error_seconds']),
    );
  }

  final int total;
  final int evaluated;
  final int? avgAbsErrorSeconds;
}

class WatchAccuracySummary {
  WatchAccuracySummary({
    required this.totalAlerts,
    required this.evaluatedAlerts,
    required this.eta30m,
    required this.eta10m,
    required this.eta5m,
    this.avgAbsErrorSeconds,
  });

  factory WatchAccuracySummary.fromJson(Map<String, dynamic> json) {
    return WatchAccuracySummary(
      totalAlerts: _asInt(json['total_alerts']) ?? 0,
      evaluatedAlerts: _asInt(json['evaluated_alerts']) ?? 0,
      avgAbsErrorSeconds: _asInt(json['avg_abs_error_seconds']),
      eta30m: WatchAccuracyBucket.fromJson(
        json['eta_30m'] as Map<String, dynamic>? ?? const {},
      ),
      eta10m: WatchAccuracyBucket.fromJson(
        json['eta_10m'] as Map<String, dynamic>? ?? const {},
      ),
      eta5m: WatchAccuracyBucket.fromJson(
        json['eta_5m'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }

  final int totalAlerts;
  final int evaluatedAlerts;
  final int? avgAbsErrorSeconds;
  final WatchAccuracyBucket eta30m;
  final WatchAccuracyBucket eta10m;
  final WatchAccuracyBucket eta5m;
}

class WatchStopStatus {
  WatchStopStatus({
    required this.stop,
    required this.refreshHintSeconds,
    required this.primaryArrivals,
    required this.announcedArrivals,
    required this.staleArrivals,
    required this.liveVehicles,
    required this.recentEvents,
    required this.accuracySummary,
    this.watchStartedAt,
    this.refreshedAt,
    this.lastError,
  });

  factory WatchStopStatus.fromJson(Map<String, dynamic> json) {
    return WatchStopStatus(
      stop: StopSummary.fromJson(
        json['stop'] as Map<String, dynamic>? ?? const {},
      ),
      watchStartedAt: json['watch_started_at']?.toString(),
      refreshedAt: json['refreshed_at']?.toString(),
      refreshHintSeconds: _asInt(json['refresh_hint_seconds']) ?? 20,
      primaryArrivals: (json['primary_arrivals'] as List<dynamic>? ?? [])
          .map((item) => Arrival.fromJson(item as Map<String, dynamic>))
          .toList(),
      announcedArrivals: (json['announced_arrivals'] as List<dynamic>? ?? [])
          .map((item) => Arrival.fromJson(item as Map<String, dynamic>))
          .toList(),
      staleArrivals: (json['stale_arrivals'] as List<dynamic>? ?? [])
          .map((item) => Arrival.fromJson(item as Map<String, dynamic>))
          .toList(),
      liveVehicles: (json['live_vehicles'] as List<dynamic>? ?? [])
          .map((item) => Vehicle.fromJson(item as Map<String, dynamic>))
          .toList(),
      recentEvents: (json['recent_events'] as List<dynamic>? ?? [])
          .map((item) => WatchEvent.fromJson(item as Map<String, dynamic>))
          .toList(),
      accuracySummary: WatchAccuracySummary.fromJson(
        json['accuracy_summary'] as Map<String, dynamic>? ?? const {},
      ),
      lastError: json['last_error']?.toString(),
    );
  }

  final StopSummary stop;
  final String? watchStartedAt;
  final String? refreshedAt;
  final int refreshHintSeconds;
  final List<Arrival> primaryArrivals;
  final List<Arrival> announcedArrivals;
  final List<Arrival> staleArrivals;
  final List<Vehicle> liveVehicles;
  final List<WatchEvent> recentEvents;
  final WatchAccuracySummary accuracySummary;
  final String? lastError;
}

class AppBootstrap {
  AppBootstrap({
    required this.routes,
    required this.stops,
    required this.defaultNearbyRadiusMeters,
  });

  factory AppBootstrap.fromJson(Map<String, dynamic> json) {
    return AppBootstrap(
      routes: (json['routes'] as List<dynamic>? ?? [])
          .map((item) => RouteSummary.fromJson(item as Map<String, dynamic>))
          .toList(),
      stops: (json['stops'] as List<dynamic>? ?? [])
          .map((item) => StopSummary.fromJson(item as Map<String, dynamic>))
          .toList(),
      defaultNearbyRadiusMeters:
          _asInt(
            (json['defaults'] as Map<String, dynamic>? ??
                const {})['nearby_radius_m'],
          ) ??
          800,
    );
  }

  final List<RouteSummary> routes;
  final List<StopSummary> stops;
  final int defaultNearbyRadiusMeters;
}

class SavedLocation {
  SavedLocation({required this.lat, required this.lng});

  factory SavedLocation.fromJson(Map<String, dynamic> json) {
    return SavedLocation(
      lat: _asDouble(json['lat']) ?? 0,
      lng: _asDouble(json['lng']) ?? 0,
    );
  }

  final double lat;
  final double lng;

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng};
}

enum LocationStatus { available, permissionDenied, serviceDisabled, error }

class LocationLookup {
  const LocationLookup({required this.status, this.position, this.message});

  final LocationStatus status;
  final SavedLocation? position;
  final String? message;
}

int? _asInt(dynamic value) {
  if (value == null) {
    return null;
  }
  return (value as num).toInt();
}

double? _asDouble(dynamic value) {
  if (value == null) {
    return null;
  }
  return (value as num).toDouble();
}
