import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/app_widgets.dart';
import '../../models/app_models.dart';
import '../../services/api_client.dart';

class RouteDetailPage extends ConsumerStatefulWidget {
  const RouteDetailPage({
    super.key,
    required this.routeId,
    this.focusedVehicleUid,
  });

  final String routeId;
  final int? focusedVehicleUid;

  @override
  ConsumerState<RouteDetailPage> createState() => _RouteDetailPageState();
}

class _RouteDetailPageState extends ConsumerState<RouteDetailPage> {
  Timer? _refreshTimer;
  RouteDetail? _detail;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _scheduleRefresh(int seconds) {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(
      Duration(seconds: seconds.clamp(3, 12).toInt()),
      () => unawaited(_load(silent: true)),
    );
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
      });
    }

    try {
      final api = ref.read(apiClientProvider);
      final detail = await api.getRouteDetail(widget.routeId);
      _scheduleRefresh(detail.refreshHintSeconds);

      if (!mounted) {
        return;
      }
      setState(() {
        _detail = detail;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      _scheduleRefresh(12);
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Vehicle? _focusedVehicle(RouteDetail detail) {
    final focusedVehicleUid = widget.focusedVehicleUid;
    if (focusedVehicleUid == null) {
      return null;
    }

    for (final vehicle in detail.activeVehicles) {
      if (vehicle.uid == focusedVehicleUid) {
        return vehicle;
      }
    }
    return null;
  }

  LatLng _centerFor(RouteDetail detail, Vehicle? focusedVehicle) {
    if (focusedVehicle != null) {
      return LatLng(
        focusedVehicle.position.lat,
        focusedVehicle.position.lng,
      );
    }
    if (detail.activeVehicles.isNotEmpty) {
      return LatLng(
        detail.activeVehicles.first.position.lat,
        detail.activeVehicles.first.position.lng,
      );
    }
    if (detail.polyline.isNotEmpty) {
      return LatLng(detail.polyline.first.lat, detail.polyline.first.lng);
    }
    if (detail.stops.isNotEmpty) {
      return LatLng(detail.stops.first.lat, detail.stops.first.lng);
    }
    return const LatLng(13.0975, -59.6130);
  }

  String _vehicleMeta(Vehicle vehicle) {
    final speed = vehicle.position.speedKph?.toStringAsFixed(0) ?? '0';
    final lat = vehicle.position.lat.toStringAsFixed(5);
    final lng = vehicle.position.lng.toStringAsFixed(5);
    return '${vehicle.statusText} • speed $speed km/h • $lat, $lng';
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final focusedVehicle = detail == null ? null : _focusedVehicle(detail);
    final visibleVehicles = detail == null
        ? const <Vehicle>[]
        : focusedVehicle != null
        ? <Vehicle>[focusedVehicle]
        : detail.activeVehicles;
    final mapCenter = detail == null
        ? const LatLng(13.0975, -59.6130)
        : _centerFor(detail, focusedVehicle);

    return Scaffold(
      appBar: AppBar(
        leading: const AppBarBackAction(),
        title: const Text('Route Detail'),
        actions: [
          IconButton(
            onPressed: () => unawaited(_load()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: AppBackground(
        child: _loading && detail == null
            ? const Center(child: CircularProgressIndicator())
            : _error != null && detail == null
            ? Center(child: Text(_error!))
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                children: [
                  SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            RoutePill(label: detail!.routeNumber),
                            ToneChip(
                              label: detail.source == 'official'
                                  ? 'Official route'
                                  : 'Live-only route',
                              color: detail.source == 'official'
                                  ? const Color(0xFF006875)
                                  : const Color(0xFF001F3F),
                            ),
                            ToneChip(
                              label: 'Auto ${detail.refreshHintSeconds}s',
                              color: const Color(0xFFB45309),
                            ),
                            if (focusedVehicle != null)
                              const ToneChip(
                                label: 'Priority Focus',
                                color: Color(0xFF006875),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          detail.routeName,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${detail.from} → ${detail.to}',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        if (detail.description.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text(
                            detail.description,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ],
                        if (focusedVehicle != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                            color: const Color(0xFF001F3F).withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(24),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Tracking Bus ${focusedVehicle.uid}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _vehicleMeta(focusedVehicle),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyMedium,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                TextButton.icon(
                                  onPressed: () =>
                                      context.go('/routes/${widget.routeId}'),
                                  icon: const Icon(Icons.layers_clear_rounded),
                                  label: const Text('Show all'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (detail.polyline.isNotEmpty || detail.stops.isNotEmpty)
                    SectionCard(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        height: 380,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: FlutterMap(
                            options: MapOptions(
                              initialCenter: mapCenter,
                              initialZoom: focusedVehicle != null ? 14.6 : 12.2,
                            ),
                            children: [
                              TileLayer(
                                urlTemplate:
                                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'barbados_bus_demo',
                              ),
                              if (detail.polyline.isNotEmpty)
                                PolylineLayer(
                                  polylines: [
                                    Polyline(
                                      points: detail.polyline
                                          .map(
                                            (point) =>
                                                LatLng(point.lat, point.lng),
                                          )
                                          .toList(),
                                      strokeWidth: 5,
                                      color: const Color(0xFF006875),
                                    ),
                                  ],
                                ),
                              if (visibleVehicles.isNotEmpty)
                                PolylineLayer(
                                  polylines: visibleVehicles
                                      .where(
                                        (vehicle) =>
                                            vehicle.previousPosition != null,
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
                              MarkerLayer(
                                markers: [
                                  ...detail.stops.map(
                                    (stop) => Marker(
                                      point: LatLng(stop.lat, stop.lng),
                                      width: 26,
                                      height: 26,
                                      child: const StopMapMarker(routeCount: 1),
                                    ),
                                  ),
                                  ...visibleVehicles.map(
                                    (vehicle) => Marker(
                                      point: LatLng(
                                        vehicle.position.lat,
                                        vehicle.position.lng,
                                      ),
                                      width: 84,
                                      height: 84,
                                      child: GestureDetector(
                                        onTap: () => context.go(
                                          '/routes/${widget.routeId}?vehicle=${vehicle.uid}',
                                        ),
                                        child: BusPulseMarker(
                                          state: vehicle.confidenceState,
                                          routeLabel: vehicle.routeNumber,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 18),
                  if (detail.activeVehicles.isNotEmpty)
                    SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            focusedVehicle != null
                                ? 'Focused vehicle'
                                : 'Live vehicles',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 14),
                          ...detail.activeVehicles.map(
                            (vehicle) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              onTap: () => context.go(
                                '/routes/${widget.routeId}?vehicle=${vehicle.uid}',
                              ),
                              title: Text(
                                'Bus ${vehicle.uid}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              subtitle: Text(_vehicleMeta(vehicle)),
                              trailing: focusedVehicle?.uid == vehicle.uid
                                  ? TextButton(
                                      onPressed: () =>
                                          context.go('/routes/${widget.routeId}'),
                                      child: const Text('All'),
                                    )
                                  : ConfidenceChip(
                                      state: vehicle.confidenceState,
                                      label: vehicle.statusText,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 18),
                  SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Stops',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 14),
                        ...detail.stops.map(
                          (stop) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFF00E5FF).withValues(alpha: 0.1),
                              foregroundColor: const Color(0xFF006875),
                              child: Text('${stop.index + 1}'),
                            ),
                            title: Text(stop.name),
                            subtitle: Text(stop.description),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (detail.schedules.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Timetable',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 14),
                          ...detail.schedules.entries.map(
                            (entry) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.key,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: entry.value
                                        .map(
                                          (time) => ToneChip(
                                            label: time,
                                            color: const Color(0xFF001F3F),
                                          ),
                                        )
                                        .toList(),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
