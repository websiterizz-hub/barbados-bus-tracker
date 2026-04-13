import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_widgets.dart';
import '../../models/app_models.dart';
import '../../services/api_client.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bootstrap = ref.watch(bootstrapProvider);
    final query = _controller.text.trim().toLowerCase();

    return Scaffold(
      appBar: AppBar(
        leading: const AppBarBackAction(),
        title: const Text('Search Bus'),
      ),
      body: AppBackground(
        child: bootstrap.when(
          data: (data) {
            final matchingStops = data.stops
                .where((stop) {
                  if (query.isEmpty) {
                    return true;
                  }
                  return '${stop.name} ${stop.description}'
                      .toLowerCase()
                      .contains(query);
                })
                .take(20)
                .toList();

            final matchingRoutes = data.routes
                .where((route) {
                  if (query.isEmpty) {
                    return true;
                  }
                  return '${route.routeNumber} ${route.routeName} ${route.from} ${route.to}'
                      .toLowerCase()
                      .contains(query);
                })
                .take(24)
                .toList();

            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              children: [
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Find routes, stops, and terminals',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _controller,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search_rounded),
                          hintText:
                              'Try Sam Lord\'s, College Savannah, Bridgetown, Warrens, 54...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(20)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                _SearchSection<RouteSummary>(
                  title: 'Routes',
                  items: matchingRoutes,
                  emptyLabel: 'No routes match that search yet.',
                  itemBuilder: (route) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${route.routeNumber} ${route.routeName}'.trim(),
                    ),
                    subtitle: Text('${route.from} -> ${route.to}'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.push('/routes/${route.id}'),
                  ),
                ),
                const SizedBox(height: 18),
                _SearchSection<StopSummary>(
                  title: 'Stops',
                  items: matchingStops,
                  emptyLabel: 'No stops match that search yet.',
                  itemBuilder: (stop) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(stop.name),
                    subtitle: Text(
                      stop.description.isEmpty
                          ? '${stop.routes.length} routes'
                          : stop.description,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.push('/stops/${stop.id}'),
                  ),
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text(error.toString())),
        ),
      ),
    );
  }
}

class _SearchSection<T> extends StatelessWidget {
  const _SearchSection({
    required this.title,
    required this.items,
    required this.emptyLabel,
    required this.itemBuilder,
  });

  final String title;
  final List<T> items;
  final String emptyLabel;
  final Widget Function(T item) itemBuilder;

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
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (items.isEmpty) Text(emptyLabel) else ...items.map(itemBuilder),
        ],
      ),
    );
  }
}
