import 'package:barbados_bus_demo/features/home/home_page.dart';
import 'package:barbados_bus_demo/features/search/search_page.dart';
import 'package:barbados_bus_demo/features/stop/stop_detail_page.dart';
import 'package:barbados_bus_demo/models/app_models.dart';
import 'package:barbados_bus_demo/services/api_client.dart';
import 'package:barbados_bus_demo/services/location_service.dart';
import 'package:barbados_bus_demo/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester,
    Widget child, {
    required BusApi api,
    required LocationService locationService,
    required AppBootstrap bootstrap,
    AppNotificationService? notificationService,
    Map<String, Object> initialPreferences = const {},
  }) async {
    SharedPreferences.setMockInitialValues(initialPreferences);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          locationServiceProvider.overrideWithValue(locationService),
          notificationServiceProvider.overrideWithValue(
            notificationService ?? FakeNotificationService(),
          ),
          bootstrapProvider.overrideWith((ref) async => bootstrap),
        ],
        child: MaterialApp(home: child),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('home page still offers search-first controls without location', (
    tester,
  ) async {
    final fakeApi = FakeBusApi(
      bootstrap: createBootstrapFixture(),
      nearbyResponse: createNearbyFixture(),
      stopDetail: createStopFixture(),
      routeDetail: createRouteFixture(),
      trackedRoutesResponse: createTrackedRoutesFixture(),
      watchStopStatus: createWatchStopFixture(),
    );

    await pumpPage(
      tester,
      const HomePage(),
      api: fakeApi,
      bootstrap: createBootstrapFixture(),
      locationService: FakeLocationService(
        const LocationLookup(
          status: LocationStatus.permissionDenied,
          message:
              'Location permission denied. Use search or recent stops instead.',
        ),
      ),
    );

    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
  });

  testWidgets('near me screen builds live map shell', (tester) async {
    final fakeApi = FakeBusApi(
      bootstrap: createBootstrapFixture(),
      nearbyResponse: createNearbyFixture(),
      stopDetail: createStopFixture(),
      routeDetail: createRouteFixture(),
      trackedRoutesResponse: createTrackedRoutesFixture(),
      watchStopStatus: createWatchStopFixture(),
    );

    await pumpPage(
      tester,
      const HomePage(),
      api: fakeApi,
      bootstrap: createBootstrapFixture(),
      locationService: FakeLocationService(
        LocationLookup(
          status: LocationStatus.available,
          position: SavedLocation(lat: 13.1, lng: -59.6),
        ),
      ),
    );

    expect(find.text('Near Me'), findsOneWidget);
    expect(find.text('Buses Near You Right Now'), findsOneWidget);
  });

  testWidgets('home page surfaces broader tracking guidance', (tester) async {
    final fakeApi = FakeBusApi(
      bootstrap: createBootstrapFixture(),
      nearbyResponse: createNearbyFixture(),
      stopDetail: createStopFixture(),
      routeDetail: createRouteFixture(),
      trackedRoutesResponse: createTrackedRoutesFixture(),
      watchStopStatus: createWatchStopFixture(),
    );

    await pumpPage(
      tester,
      const HomePage(),
      api: fakeApi,
      bootstrap: createBootstrapFixture(),
      locationService: FakeLocationService(
        LocationLookup(
          status: LocationStatus.available,
          position: SavedLocation(lat: 13.1, lng: -59.6),
        ),
      ),
    );

    expect(
      find.textContaining(
        'Route Radar and island view below show the other corridors too.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('near me status chips filter down to announced routes', (
    tester,
  ) async {
    final fakeApi = FakeBusApi(
      bootstrap: createBootstrapFixture(),
      nearbyResponse: createMixedNearbyFixture(),
      stopDetail: createStopFixture(),
      routeDetail: createRouteFixture(),
      trackedRoutesResponse: createTrackedRoutesFixture(),
      watchStopStatus: createWatchStopFixture(),
    );

    await pumpPage(
      tester,
      const HomePage(),
      api: fakeApi,
      bootstrap: createBootstrapFixture(),
      locationService: FakeLocationService(
        LocationLookup(
          status: LocationStatus.available,
          position: SavedLocation(lat: 13.1, lng: -59.6),
        ),
      ),
    );

    await tester.tap(find.text('Announced 1').first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.text(
        'These routes are near your area but not tied to live telemetry yet.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('home page auto-watches nearby stop instead of legacy default', (
    tester,
  ) async {
    final bootstrap = createBootstrapFixture();
    final nearby = createNearbyFixture();
    final localStop = bootstrap.stops.first;
    final localStatus = WatchStopStatus(
      stop: localStop,
      watchStartedAt: '2026-04-10T12:00:00.000Z',
      refreshedAt: '2026-04-10T12:02:00.000Z',
      refreshHintSeconds: 2,
      primaryArrivals: [createTrackingArrival()],
      announcedArrivals: const [],
      staleArrivals: const [],
      liveVehicles: nearby.nearbyVehicles,
      recentEvents: [
        WatchEvent(
          id: 'local-watch-1',
          kind: 'observed_pass',
          message:
              '54 toward Oistins passed Princess Alice Terminal from live telemetry.',
          happenedAt: '2026-04-10T12:02:20.000Z',
          stopId: localStop.id,
          stopName: localStop.name,
          routeId: 'bus-1',
          routeNumber: '54',
          routeName: 'ABC Highway',
          routeDirection: 'Speightstown -> Oistins',
          destinationName: 'Oistins',
          vehicleUid: 42,
          currentStopDistanceM: 88,
        ),
      ],
      accuracySummary: WatchAccuracySummary(
        totalAlerts: 1,
        evaluatedAlerts: 1,
        avgAbsErrorSeconds: 30,
        eta30m: WatchAccuracyBucket(total: 0, evaluated: 0),
        eta10m: WatchAccuracyBucket(total: 0, evaluated: 0),
        eta5m: WatchAccuracyBucket(
          total: 1,
          evaluated: 1,
          avgAbsErrorSeconds: 30,
        ),
      ),
      lastError: null,
    );
    final fakeApi = FakeBusApi(
      bootstrap: bootstrap,
      nearbyResponse: nearby,
      stopDetail: createStopFixture(),
      routeDetail: createRouteFixture(),
      trackedRoutesResponse: createTrackedRoutesFixture(),
      watchStopStatus: createWatchStopFixture(),
      watchStatusesByStopId: {
        localStop.id: localStatus,
        460747: createWatchStopFixture(),
      },
    );

    await pumpPage(
      tester,
      const HomePage(),
      api: fakeApi,
      bootstrap: bootstrap,
      locationService: FakeLocationService(
        LocationLookup(
          status: LocationStatus.available,
          position: SavedLocation(lat: 13.1, lng: -59.6),
        ),
      ),
      initialPreferences: {
        'watched_stops': <String>['460747'],
      },
    );

    expect(fakeApi.watchStopRequests, contains(localStop.id));
    expect(fakeApi.watchStopRequests, isNot(contains(460747)));
  });

  testWidgets('near me map can focus a tracked bus', (tester) async {
    final fakeApi = FakeBusApi(
      bootstrap: createBootstrapFixture(),
      nearbyResponse: createNearbyFixture(),
      stopDetail: createStopFixture(),
      routeDetail: createRouteFixture(),
      trackedRoutesResponse: createTrackedRoutesFixture(),
      watchStopStatus: createWatchStopFixture(),
    );

    await pumpPage(
      tester,
      const HomePage(),
      api: fakeApi,
      bootstrap: createBootstrapFixture(),
      locationService: FakeLocationService(
        LocationLookup(
          status: LocationStatus.available,
          position: SavedLocation(lat: 13.1, lng: -59.6),
        ),
      ),
    );

    expect(find.text('Buses Near You Right Now'), findsOneWidget);
    final target = find.text('Toward Oistins').first;
    await tester.scrollUntilVisible(
      target,
      280,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(target, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Focused Bus'), findsOneWidget);
    expect(find.textContaining('GPS'), findsOneWidget);
  });

  testWidgets('search page shows matching routes and stops', (tester) async {
    final fakeApi = FakeBusApi(
      bootstrap: createBootstrapFixture(),
      nearbyResponse: createNearbyFixture(),
      stopDetail: createStopFixture(),
      routeDetail: createRouteFixture(),
      trackedRoutesResponse: createTrackedRoutesFixture(),
      watchStopStatus: createWatchStopFixture(),
    );

    await pumpPage(
      tester,
      const SearchPage(),
      api: fakeApi,
      bootstrap: createBootstrapFixture(),
      locationService: FakeLocationService(
        const LocationLookup(status: LocationStatus.permissionDenied),
      ),
    );

    await tester.enterText(find.byType(TextField), 'ABC');
    await tester.pumpAndSettle();

    expect(find.textContaining('ABC Highway'), findsWidgets);
  });

  testWidgets('stop detail renders refreshed arrivals cleanly', (tester) async {
    final fakeApi = FakeBusApi(
      bootstrap: createBootstrapFixture(),
      nearbyResponse: createNearbyFixture(),
      stopDetail: createStopFixture(),
      routeDetail: createRouteFixture(),
      trackedRoutesResponse: createTrackedRoutesFixture(),
      watchStopStatus: createWatchStopFixture(),
    );

    await pumpPage(
      tester,
      const StopDetailPage(stopId: 1001),
      api: fakeApi,
      bootstrap: createBootstrapFixture(),
      locationService: FakeLocationService(
        const LocationLookup(status: LocationStatus.permissionDenied),
      ),
    );

    expect(find.text('Live now'), findsOneWidget);
    expect(find.text('Announced later'), findsOneWidget);
    expect(find.textContaining('ABC Highway'), findsWidgets);
  });
}
