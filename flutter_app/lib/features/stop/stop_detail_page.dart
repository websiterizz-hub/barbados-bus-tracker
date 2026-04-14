import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_widgets.dart';
import '../../core/time_format.dart';
import '../../core/storage.dart';
import '../../models/app_models.dart';
import '../../services/api_client.dart';
import '../../services/location_service.dart';

class StopDetailPage extends ConsumerStatefulWidget {
  const StopDetailPage({super.key, required this.stopId});

  final int stopId;

  @override
  ConsumerState<StopDetailPage> createState() => _StopDetailPageState();
}

class _StopDetailPageState extends ConsumerState<StopDetailPage> {
  Timer? _refreshTimer;
  StopDetail? _detail;
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
      Duration(seconds: seconds.clamp(5, 30).toInt()),
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
      final locationLookup =
          await ref.read(locationServiceProvider).getCurrentLocation();
      double? vLat;
      double? vLng;
      if (locationLookup.status == LocationStatus.available &&
          locationLookup.position != null) {
        vLat = locationLookup.position!.lat;
        vLng = locationLookup.position!.lng;
      }
      final detail = await api.getStopDetail(
        widget.stopId,
        viewerLat: vLat,
        viewerLng: vLng,
      );
      final storage = await ref.read(storageProvider.future);
      await storage.saveRecentStop(widget.stopId);
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
      _scheduleRefresh(30);
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const AppBarBackAction(),
        title: const Text('Stop Detail'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: AppBackground(
        child: _loading && _detail == null
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _detail == null
            ? Center(child: Text(_error!))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                  children: [
                    SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _detail!.stop.name,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _detail!.stop.description.isEmpty
                                ? '${_detail!.stop.routes.length} routes serve this stop'
                                : _detail!.stop.description,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              ToneChip(
                                label: 'Auto ${_detail!.refreshHintSeconds}s',
                                color: const Color(0xFFB45309),
                              ),
                              if (_detail!.confidenceSummary.tracking > 0)
                                ToneChip(
                                  label:
                                      '${_detail!.confidenceSummary.tracking} tracking',
                                  color: confidenceColor('tracking'),
                                ),
                              if (_detail!.confidenceSummary.atTerminal > 0)
                                ToneChip(
                                  label:
                                      '${_detail!.confidenceSummary.atTerminal} at terminal',
                                  color: confidenceColor('at_terminal'),
                                ),
                              if (_detail!.confidenceSummary.announced > 0)
                                ToneChip(
                                  label:
                                      '${_detail!.confidenceSummary.announced} announced',
                                  color: const Color(0xFF001F3F),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _detail!.stop.routes
                                .map(
                                  (route) =>
                                      RoutePill(label: route.routeNumber),
                                )
                                .toList(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    _ArrivalGroupCard(
                      title: 'Live now',
                      emptyLabel:
                          'No live-tracked or terminal-confirmed arrivals yet.',
                      arrivals: _detail!.primaryArrivals,
                    ),
                    const SizedBox(height: 18),
                    _ArrivalGroupCard(
                      title: 'Announced later',
                      emptyLabel:
                          'No schedule-only announcements at this stop right now.',
                      arrivals: _detail!.announcedArrivals,
                    ),
                    if (_detail!.staleArrivals.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _ArrivalGroupCard(
                        title: 'Signal issues',
                        emptyLabel: '',
                        arrivals: _detail!.staleArrivals,
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _ArrivalGroupCard extends StatelessWidget {
  const _ArrivalGroupCard({
    required this.title,
    required this.emptyLabel,
    required this.arrivals,
  });

  final String title;
  final String emptyLabel;
  final List<Arrival> arrivals;

  String _subtitleFor(Arrival arrival) {
    switch (arrival.confidenceState) {
      case 'tracking':
        return 'Tracking • ${formatArrivalEtaForDisplay(arrival)}';
      case 'at_terminal':
        final walk = arrival.watchEtaLabel;
        if (walk != null && walk.isNotEmpty) {
          return 'At terminal • scheduled ${arrival.scheduledLabel} • $walk';
        }
        return 'At terminal • scheduled ${arrival.scheduledLabel}';
      case 'stale':
        return arrival.statusText;
      default:
        return 'Announced • after ${arrival.scheduledLabel}';
    }
  }

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
          const SizedBox(height: 14),
          if (arrivals.isEmpty && emptyLabel.isNotEmpty)
            Text(emptyLabel, style: Theme.of(context).textTheme.bodyLarge)
          else
            ...arrivals.map(
              (arrival) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${arrival.routeNumber} ${arrival.routeName}'.trim(),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(_subtitleFor(arrival)),
                trailing: ConfidenceChip(
                  state: arrival.confidenceState,
                  label: arrival.confidenceState == 'tracking'
                      ? formatArrivalEtaForDisplay(arrival)
                      : arrival.statusText,
                ),
                onTap: () => context.push('/routes/${arrival.routeId}'),
              ),
            ),
        ],
      ),
    );
  }
}
