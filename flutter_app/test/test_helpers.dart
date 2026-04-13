import 'package:barbados_bus_demo/models/app_models.dart';
import 'package:barbados_bus_demo/services/api_client.dart';
import 'package:barbados_bus_demo/services/location_service.dart';
import 'package:barbados_bus_demo/services/notification_service.dart';

class FakeBusApi implements BusApi {
  FakeBusApi({
    required this.bootstrap,
    required this.nearbyResponse,
    required this.stopDetail,
    required this.routeDetail,
    required this.trackedRoutesResponse,
    required this.watchStopStatus,
    this.watchStatusesByStopId,
  });

  final AppBootstrap bootstrap;
  final NearbyResponse nearbyResponse;
  final StopDetail stopDetail;
  final RouteDetail routeDetail;
  final TrackedRoutesResponse trackedRoutesResponse;
  final WatchStopStatus watchStopStatus;
  final Map<int, WatchStopStatus>? watchStatusesByStopId;
  final List<int> watchStopRequests = <int>[];

  @override
  Future<AppBootstrap> getBootstrap() async => bootstrap;

  @override
  Future<NearbyResponse> getNearbyStops({
    required double lat,
    required double lng,
    required int radiusMeters,
    int limit = 8,
  }) async {
    return nearbyResponse;
  }

  @override
  Future<RouteDetail> getRouteDetail(String routeId) async => routeDetail;

  @override
  Future<StopDetail> getStopDetail(
    int stopId, {
    double? viewerLat,
    double? viewerLng,
  }) async =>
      stopDetail;

  @override
  Future<TrackedRoutesResponse> getTrackedRoutes() async =>
      trackedRoutesResponse;

  @override
  Future<WatchStopStatus> getWatchStopStatus(int stopId) async {
    watchStopRequests.add(stopId);
    return watchStatusesByStopId?[stopId] ?? watchStopStatus;
  }
}

class FakeLocationService implements LocationService {
  FakeLocationService(this.lookup);

  final LocationLookup lookup;

  @override
  Future<LocationLookup> getCurrentLocation() async => lookup;

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;
}

class FakeNotificationService implements AppNotificationService {
  FakeNotificationService({
    this.setup = const NotificationSetup(
      supported: false,
      granted: false,
      label: 'In-app alerts only',
    ),
  });

  final NotificationSetup setup;
  final List<WatchEvent> shownEvents = <WatchEvent>[];

  @override
  Future<NotificationSetup> initialize() async => setup;

  @override
  Future<NotificationSetup> requestPermission() async => setup;

  @override
  Future<void> showWatchEvent({
    required WatchStopStatus status,
    required WatchEvent event,
  }) async {
    shownEvents.add(event);
  }

  @override
  Future<void> showStickyLocalAlert({
    required String title,
    required String body,
    required int notificationId,
  }) async {}
}

AppBootstrap createBootstrapFixture() {
  final watchStatus = createWatchStopFixture();
  return AppBootstrap(
    defaultNearbyRadiusMeters: 800,
    routes: [
      RouteSummary(
        id: 'bus-1',
        routeNumber: '54',
        routeName: 'ABC Highway',
        from: 'Speightstown',
        to: 'Oistins',
        source: 'official',
        hasLiveRoute: true,
        busId: 1,
        liveRouteId: 5001,
      ),
      watchStatus.stop.routes.first,
    ],
    stops: [
      StopSummary(
        id: 1001,
        name: 'Princess Alice Terminal',
        description: 'Bridgetown',
        lat: 13.1,
        lng: -59.6,
        routes: [
          RouteSummary(
            id: 'bus-1',
            routeNumber: '54',
            routeName: 'ABC Highway',
            from: 'Speightstown',
            to: 'Oistins',
            source: 'official',
            hasLiveRoute: true,
            busId: 1,
            liveRouteId: 5001,
          ),
        ],
      ),
      watchStatus.stop,
    ],
  );
}

Arrival createTrackingArrival() {
  return Arrival(
    routeId: 'bus-1',
    routeNumber: '54',
    routeName: 'ABC Highway',
    direction: 'Speightstown -> Oistins',
    etaSeconds: 300,
    etaLabel: '5 min',
    etaType: 'live',
    scheduledTime: null,
    scheduledLabel: '10:55 pm',
    delaySeconds: 30,
    vehicleUid: 42,
    freshness: 'fresh',
    routeSource: 'official',
    confidenceState: 'tracking',
    confidenceScore: 0.9,
    statusText: 'Tracking',
    liveTracking: true,
    movementM90s: 210,
    progressDelta90s: 0.4,
    lastSeenSeconds: 4,
    originDistanceM: 220,
    busId: 1,
    liveRouteId: 5001,
  );
}

Arrival createAnnouncedArrival() {
  return Arrival(
    routeId: 'bus-1',
    routeNumber: '54',
    routeName: 'ABC Highway',
    direction: 'Speightstown -> Oistins',
    etaSeconds: 1800,
    etaLabel: '11:20 pm',
    etaType: 'schedule',
    scheduledTime: null,
    scheduledLabel: '11:20 pm',
    delaySeconds: 0,
    vehicleUid: null,
    freshness: 'schedule',
    routeSource: 'official',
    confidenceState: 'announced',
    confidenceScore: 0.2,
    statusText: 'Announced',
    liveTracking: false,
    movementM90s: 0,
    progressDelta90s: 0,
    busId: 1,
    liveRouteId: 5001,
  );
}

Arrival createUntrackedAnnouncedArrival() {
  return Arrival(
    routeId: 'bus-167',
    routeNumber: '12A',
    routeName: "Sam Lord's Castle",
    direction: "Sam Lords Castle -> Fairchild Street Terminal",
    etaSeconds: 1200,
    etaLabel: '9:55 pm',
    etaType: 'schedule',
    scheduledTime: null,
    scheduledLabel: '9:55 pm',
    delaySeconds: 0,
    vehicleUid: null,
    freshness: 'schedule',
    routeSource: 'official',
    confidenceState: 'announced',
    confidenceScore: 0.2,
    statusText: 'Announced',
    liveTracking: false,
    movementM90s: 0,
    progressDelta90s: 0,
    busId: 167,
    liveRouteId: 54882,
  );
}

NearbyResponse createNearbyFixture() {
  final stop = createBootstrapFixture().stops.first;
  return NearbyResponse(
    radiusMeters: 800,
    refreshHintSeconds: 5,
    nearbyVehicles: [
      Vehicle(
        uid: 42,
        routeId: 5001,
        routeNumber: '54',
        routeDirection: 'Speightstown -> Oistins',
        tripScheduleId: 123,
        delaySeconds: 30,
        ageSeconds: 12,
        fresh: true,
        confidenceState: 'tracking',
        confidenceScore: 0.9,
        statusText: 'Tracking',
        liveTracking: true,
        moving: true,
        movementM90s: 210,
        progressDelta90s: 0.4,
        originDistanceM: 220,
        lastSeenSeconds: 5,
        position: GeoPoint(lat: 13.11, lng: -59.61, speedKph: 28, heading: 90),
        previousPosition: GeoPoint(lat: 13.105, lng: -59.605),
      ),
    ],
    nearbyStops: [
      NearbyStop(
        stop: stop,
        distanceMeters: 120,
        arrivals: [createTrackingArrival(), createAnnouncedArrival()],
        primaryArrivals: [createTrackingArrival()],
        announcedArrivals: [createAnnouncedArrival()],
        staleArrivals: const [],
        confidenceSummary: ConfidenceSummary(
          tracking: 1,
          atTerminal: 0,
          announced: 1,
          stale: 0,
        ),
      ),
    ],
  );
}

NearbyResponse createMixedNearbyFixture() {
  final bootstrap = createBootstrapFixture();
  final stop = StopSummary(
    id: bootstrap.stops.first.id,
    name: bootstrap.stops.first.name,
    description: bootstrap.stops.first.description,
    lat: bootstrap.stops.first.lat,
    lng: bootstrap.stops.first.lng,
    routes: [
      ...bootstrap.stops.first.routes,
      RouteSummary(
        id: 'bus-167',
        routeNumber: '12A',
        routeName: "Sam Lord's Castle",
        from: 'Sam Lords Castle',
        to: 'Fairchild Street Terminal',
        source: 'official',
        hasLiveRoute: true,
        busId: 167,
        liveRouteId: 54882,
      ),
    ],
  );

  return NearbyResponse(
    radiusMeters: 800,
    refreshHintSeconds: 5,
    nearbyVehicles: [
      Vehicle(
        uid: 42,
        routeId: 5001,
        routeNumber: '54',
        routeDirection: 'Speightstown -> Oistins',
        tripScheduleId: 123,
        delaySeconds: 30,
        ageSeconds: 12,
        fresh: true,
        confidenceState: 'tracking',
        confidenceScore: 0.9,
        statusText: 'Tracking',
        liveTracking: true,
        moving: true,
        movementM90s: 210,
        progressDelta90s: 0.4,
        originDistanceM: 220,
        lastSeenSeconds: 5,
        position: GeoPoint(lat: 13.11, lng: -59.61, speedKph: 28, heading: 90),
        previousPosition: GeoPoint(lat: 13.105, lng: -59.605),
      ),
    ],
    nearbyStops: [
      NearbyStop(
        stop: stop,
        distanceMeters: 120,
        arrivals: [createAnnouncedArrival(), createUntrackedAnnouncedArrival()],
        primaryArrivals: const [],
        announcedArrivals: [
          createAnnouncedArrival(),
          createUntrackedAnnouncedArrival(),
        ],
        staleArrivals: const [],
        confidenceSummary: ConfidenceSummary(
          tracking: 0,
          atTerminal: 0,
          announced: 2,
          stale: 0,
        ),
      ),
    ],
  );
}

StopDetail createStopFixture() {
  final stop = createBootstrapFixture().stops.first;
  return StopDetail(
    stop: stop,
    arrivals: [createTrackingArrival(), createAnnouncedArrival()],
    primaryArrivals: [createTrackingArrival()],
    announcedArrivals: [createAnnouncedArrival()],
    staleArrivals: const [],
    confidenceSummary: ConfidenceSummary(
      tracking: 1,
      atTerminal: 0,
      announced: 1,
      stale: 0,
    ),
    refreshHintSeconds: 5,
  );
}

RouteDetail createRouteFixture() {
  return RouteDetail(
    id: 'bus-1',
    routeNumber: '54',
    routeName: 'ABC Highway',
    from: 'Speightstown',
    to: 'Oistins',
    direction: 'Speightstown -> Oistins',
    source: 'official',
    description: 'Main island corridor',
    specialNotes: '',
    schedules: {
      'Mon - Fri': ['06:00', '07:00'],
    },
    stops: [
      RouteStop(
        index: 0,
        id: 1001,
        name: 'Princess Alice Terminal',
        description: 'Bridgetown',
        lat: 13.1,
        lng: -59.6,
      ),
    ],
    polyline: [
      GeoPoint(lat: 13.1, lng: -59.6),
      GeoPoint(lat: 13.2, lng: -59.7),
    ],
    activeVehicles: [
      Vehicle(
        uid: 42,
        routeId: 5001,
        routeNumber: '54',
        routeDirection: 'Speightstown -> Oistins',
        tripScheduleId: 123,
        delaySeconds: 30,
        ageSeconds: 12,
        fresh: true,
        confidenceState: 'tracking',
        confidenceScore: 0.9,
        statusText: 'Tracking',
        liveTracking: true,
        moving: true,
        movementM90s: 210,
        progressDelta90s: 0.4,
        originDistanceM: 220,
        lastSeenSeconds: 5,
        position: GeoPoint(lat: 13.11, lng: -59.61, speedKph: 28, heading: 90),
        previousPosition: GeoPoint(lat: 13.105, lng: -59.605),
      ),
    ],
    refreshHintSeconds: 5,
    busId: 1,
    liveRouteId: 5001,
    liveRouteUrl: 'https://example.test/route/5001',
  );
}

TrackedRoutesResponse createTrackedRoutesFixture() {
  return TrackedRoutesResponse(
    routeCount: 1,
    vehicleCount: 1,
    refreshHintSeconds: 5,
    routes: [
      TrackedRoute(
        id: 'bus-1',
        routeNumber: '54',
        routeName: 'ABC Highway',
        from: 'Speightstown',
        to: 'Oistins',
        source: 'official',
        direction: 'Speightstown -> Oistins',
        trackingCount: 1,
        atTerminalCount: 0,
        totalVehicles: 1,
        activeVehicles: createRouteFixture().activeVehicles,
        busId: 1,
        liveRouteId: 5001,
        topState: 'tracking',
        topStatusText: 'Tracking',
      ),
    ],
  );
}

WatchStopStatus createWatchStopFixture() {
  final stop = StopSummary(
    id: 460747,
    name: 'Foul Bay',
    description: '',
    lat: 13.11,
    lng: -59.45,
    routes: [
      RouteSummary(
        id: 'bus-167',
        routeNumber: '12A',
        routeName: "Sam Lord's Castle",
        from: 'Sam Lords Castle',
        to: 'Fairchild Street Terminal',
        source: 'official',
        hasLiveRoute: true,
        busId: 167,
        liveRouteId: 54882,
      ),
    ],
  );

  return WatchStopStatus(
    stop: stop,
    watchStartedAt: '2026-04-10T12:00:00.000Z',
    refreshedAt: '2026-04-10T12:02:00.000Z',
    refreshHintSeconds: 5,
    primaryArrivals: [
      Arrival(
        routeId: 'bus-167',
        routeNumber: '12A',
        routeName: "Sam Lord's Castle",
        direction: "Sam Lords Castle -> Fairchild Street Terminal",
        etaSeconds: 300,
        etaLabel: '5 min',
        etaType: 'live',
        scheduledTime: null,
        scheduledLabel: '8:05 am',
        delaySeconds: 0,
        vehicleUid: 42,
        freshness: 'fresh',
        routeSource: 'official',
        confidenceState: 'tracking',
        confidenceScore: 0.9,
        statusText: 'Tracking',
        liveTracking: true,
        movementM90s: 250,
        progressDelta90s: 0.4,
        lastSeenSeconds: 3,
        originDistanceM: 4200,
        busId: 167,
        liveRouteId: 54882,
      ),
    ],
    announcedArrivals: const [],
    staleArrivals: const [],
    liveVehicles: [
      Vehicle(
        uid: 29263909,
        routeId: 54991,
        routeNumber: '26',
        routeDirection: 'Oistins towards College Savannah',
        tripScheduleId: 1079671,
        derivedRouteName: 'College Savannah/Oistins',
        delaySeconds: 637,
        ageSeconds: 4,
        fresh: true,
        confidenceState: 'tracking',
        confidenceScore: 0.9,
        statusText: 'Tracking',
        liveTracking: true,
        moving: true,
        movementM90s: 188,
        progressDelta90s: 0.18,
        originDistanceM: 4300,
        lastSeenSeconds: 4,
        distanceMeters: 36,
        position: GeoPoint(
          lat: 13.1108,
          lng: -59.4502,
          speedKph: 31,
          heading: 92,
        ),
        previousPosition: GeoPoint(lat: 13.1101, lng: -59.4512),
      ),
    ],
    recentEvents: [
      WatchEvent(
        id: 'watch-1',
        kind: 'upstream_pass',
        message:
            '12A Sam Lord\'s Castle just passed Kirtons and is heading for Foul Bay.',
        happenedAt: '2026-04-10T12:01:00.000Z',
        stopId: 460747,
        stopName: 'Foul Bay',
        routeId: 'bus-167',
        routeNumber: '12A',
        routeName: "Sam Lord's Castle",
        routeDirection: "Sam Lords Castle towards Fairchild Street Terminal",
        originName: 'Sam Lords Castle',
        destinationName: 'Fairchild Street Terminal',
        vehicleUid: 42,
        upstreamStopId: 1000,
        upstreamStopName: 'Kirtons',
      ),
      WatchEvent(
        id: 'watch-2',
        kind: 'alert_eta_30m',
        message: '12A Sam Lord\'s Castle nearing Foul Bay in about 30 min.',
        happenedAt: '2026-04-10T11:35:00.000Z',
        stopId: 460747,
        stopName: 'Foul Bay',
        routeId: 'bus-167',
        routeNumber: '12A',
        routeName: "Sam Lord's Castle",
        routeDirection: "Sam Lords Castle towards Fairchild Street Terminal",
        originName: 'Sam Lords Castle',
        destinationName: 'Fairchild Street Terminal',
        vehicleUid: 42,
      ),
      WatchEvent(
        id: 'watch-3',
        kind: 'observed_pass',
        message:
            '12A toward Fairchild Street Terminal passed Foul Bay from live telemetry.',
        happenedAt: '2026-04-10T12:02:20.000Z',
        stopId: 460747,
        stopName: 'Foul Bay',
        routeId: 'bus-167',
        routeNumber: '12A',
        routeName: "Sam Lord's Castle",
        routeDirection: "Sam Lords Castle towards Fairchild Street Terminal",
        originName: 'Sam Lords Castle',
        destinationName: 'Fairchild Street Terminal',
        vehicleUid: 42,
        currentStopDistanceM: 152,
      ),
      WatchEvent(
        id: 'watch-4',
        kind: 'prediction_evaluated',
        message:
            '12A Sam Lord\'s Castle reached Foul Bay 45s after predicted time.',
        happenedAt: '2026-04-10T12:03:00.000Z',
        stopId: 460747,
        stopName: 'Foul Bay',
        routeId: 'bus-167',
        routeNumber: '12A',
        routeName: "Sam Lord's Castle",
        routeDirection: "Sam Lords Castle towards Fairchild Street Terminal",
        originName: 'Sam Lords Castle',
        destinationName: 'Fairchild Street Terminal',
        vehicleUid: 42,
        errorSeconds: 45,
        currentStopDistanceM: 62,
      ),
    ],
    accuracySummary: WatchAccuracySummary(
      totalAlerts: 1,
      evaluatedAlerts: 1,
      avgAbsErrorSeconds: 45,
      eta30m: WatchAccuracyBucket(total: 0, evaluated: 0),
      eta10m: WatchAccuracyBucket(total: 0, evaluated: 0),
      eta5m: WatchAccuracyBucket(
        total: 1,
        evaluated: 1,
        avgAbsErrorSeconds: 45,
      ),
    ),
    lastError: null,
  );
}
