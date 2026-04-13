import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_models.dart';

const _defaultApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:3000',
);

final apiClientProvider = Provider<BusApi>((ref) {
  return HttpBusApi(
    Dio(
      BaseOptions(
        baseUrl: _defaultApiBaseUrl,
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 12),
      ),
    ),
  );
});

final bootstrapProvider = FutureProvider<AppBootstrap>((ref) async {
  return ref.read(apiClientProvider).getBootstrap();
});

abstract class BusApi {
  Future<AppBootstrap> getBootstrap();
  Future<NearbyResponse> getNearbyStops({
    required double lat,
    required double lng,
    required int radiusMeters,
    int limit = 8,
  });
  Future<StopDetail> getStopDetail(
    int stopId, {
    double? viewerLat,
    double? viewerLng,
  });
  Future<RouteDetail> getRouteDetail(String routeId);
  Future<TrackedRoutesResponse> getTrackedRoutes();
  Future<WatchStopStatus> getWatchStopStatus(int stopId);
}

class HttpBusApi implements BusApi {
  HttpBusApi(this._dio);

  final Dio _dio;

  @override
  Future<AppBootstrap> getBootstrap() async {
    final response = await _dio.get<Map<String, dynamic>>('/api/bootstrap');
    return AppBootstrap.fromJson(response.data ?? const {});
  }

  @override
  Future<NearbyResponse> getNearbyStops({
    required double lat,
    required double lng,
    required int radiusMeters,
    int limit = 8,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/nearby',
      queryParameters: {
        'lat': lat,
        'lng': lng,
        'radius_m': radiusMeters,
        'limit': limit,
      },
    );
    return NearbyResponse.fromJson(response.data ?? const {});
  }

  @override
  Future<StopDetail> getStopDetail(
    int stopId, {
    double? viewerLat,
    double? viewerLng,
  }) async {
    final query = <String, dynamic>{};
    if (viewerLat != null && viewerLng != null) {
      query['lat'] = viewerLat;
      query['lng'] = viewerLng;
    }
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/stops/$stopId',
      queryParameters: query.isEmpty ? null : query,
    );
    return StopDetail.fromJson(response.data ?? const {});
  }

  @override
  Future<RouteDetail> getRouteDetail(String routeId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/routes/${Uri.encodeComponent(routeId)}',
    );
    return RouteDetail.fromJson(response.data ?? const {});
  }

  @override
  Future<TrackedRoutesResponse> getTrackedRoutes() async {
    final response = await _dio.get<Map<String, dynamic>>('/api/tracked');
    return TrackedRoutesResponse.fromJson(response.data ?? const {});
  }

  @override
  Future<WatchStopStatus> getWatchStopStatus(int stopId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/watch/stops/$stopId',
    );
    return WatchStopStatus.fromJson(response.data ?? const {});
  }
}
