import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/app_theme.dart';
import 'features/home/home_page.dart';
import 'features/route/route_detail_page.dart';
import 'features/search/search_page.dart';
import 'features/stop/stop_detail_page.dart';

class BarbadosBusDemoApp extends StatelessWidget {
  const BarbadosBusDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => const HomePage()),
        GoRoute(
          path: '/search',
          builder: (context, state) => const SearchPage(),
        ),
        GoRoute(
          path: '/stops/:stopId',
          builder: (context, state) => StopDetailPage(
            stopId: int.parse(state.pathParameters['stopId']!),
          ),
        ),
        GoRoute(
          path: '/routes/:routeId',
          builder: (context, state) => RouteDetailPage(
            routeId: state.pathParameters['routeId']!,
            focusedVehicleUid: int.tryParse(
              state.uri.queryParameters['vehicle'] ?? '',
            ),
          ),
        ),
      ],
    );

    return MaterialApp.router(
      title: 'Barbados Bus Tracker',
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      routerConfig: router,
    );
  }
}
