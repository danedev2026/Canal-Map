import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'routing.dart';

/// A well-known cruising route ("ring") with a precomputed polyline, bundled as
/// an asset (built by build_popular_routes.py over the same routing graph).
/// Tapping one draws it on the map like any other route.
class PopularRoute {
  PopularRoute({
    required this.name,
    required this.description,
    required this.miles,
    required this.locks,
    required this.etaMinutes,
    required this.poly,
  });

  final String name;
  final String description;
  final double miles;
  final int locks;
  final int etaMinutes;
  final List<LatLng> poly;

  Duration get eta => Duration(minutes: etaMinutes);

  /// Present it as a RouteResult so the map can draw + describe it (journey
  /// plan, save, export) exactly like a planned route.
  RouteResult toResult() =>
      RouteResult(poly, miles * 1609.34, locks, eta);

  factory PopularRoute.fromJson(Map<String, dynamic> j) => PopularRoute(
        name: j['name'] as String,
        description: j['description'] as String,
        miles: (j['miles'] as num).toDouble(),
        locks: (j['locks'] as num).toInt(),
        etaMinutes: (j['etaMinutes'] as num).toInt(),
        poly: [
          for (final p in (j['poly'] as List))
            LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
        ],
      );

  static Future<List<PopularRoute>> load() async {
    final raw = await rootBundle.loadString('assets/popular_routes.json');
    return (jsonDecode(raw) as List)
        .map((e) => PopularRoute.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
