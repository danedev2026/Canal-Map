import 'dart:convert';
import 'dart:io';

import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';

import 'routing.dart';

/// A route the user chose to keep. Stores enough to redraw it and show its
/// figures without recomputing — the full polyline plus distance/locks/time.
/// Local only (docs/saved_routes.json); never leaves the device.
class SavedRoute {
  SavedRoute({
    required this.name,
    required this.savedAt,
    required this.polyline,
    required this.metres,
    required this.locks,
    required this.etaMinutes,
  });

  final String name;
  final DateTime savedAt;
  final List<LatLng> polyline;
  final double metres;
  final int locks;
  final int etaMinutes;

  double get miles => metres / 1609.34;
  Duration get eta => Duration(minutes: etaMinutes);
  LatLng get start => polyline.first;
  LatLng get end => polyline.last;

  /// Rebuild a RouteResult so the map can draw + describe it like a fresh route.
  RouteResult toResult() => RouteResult(polyline, metres, locks, eta);

  factory SavedRoute.fromResult(String name, RouteResult r) => SavedRoute(
        name: name,
        savedAt: DateTime.now(),
        polyline: r.polyline,
        metres: r.metres,
        locks: r.locks,
        etaMinutes: r.eta.inMinutes,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'savedAt': savedAt.toIso8601String(),
        'metres': metres,
        'locks': locks,
        'etaMinutes': etaMinutes,
        // Compact [lat,lon] pairs rounded to ~1 m to keep the file small.
        'poly': polyline
            .map((p) => [
                  double.parse(p.latitude.toStringAsFixed(6)),
                  double.parse(p.longitude.toStringAsFixed(6)),
                ])
            .toList(),
      };

  factory SavedRoute.fromJson(Map<String, dynamic> j) => SavedRoute(
        name: (j['name'] ?? 'Route') as String,
        savedAt: DateTime.tryParse((j['savedAt'] ?? '') as String) ?? DateTime.now(),
        metres: (j['metres'] as num).toDouble(),
        locks: (j['locks'] as num).toInt(),
        etaMinutes: (j['etaMinutes'] as num).toInt(),
        polyline: [
          for (final p in (j['poly'] as List))
            LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
        ],
      );
}

/// Local store for saved routes. Newest first.
class SavedRoutes {
  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/saved_routes.json');
  }

  static Future<List<SavedRoute>> load() async {
    final f = await _file();
    if (!await f.exists()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      final out = list
          .map((e) => SavedRoute.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<void> add(SavedRoute r) async {
    final all = await load()..insert(0, r);
    await _write(all);
  }

  static Future<void> delete(SavedRoute r) async {
    final all = await load()
      ..removeWhere((e) => e.savedAt == r.savedAt && e.name == r.name);
    await _write(all);
  }

  static Future<void> _write(List<SavedRoute> routes) async {
    final f = await _file();
    await f.writeAsString(
        jsonEncode(routes.map((e) => e.toJson()).toList()), flush: true);
  }
}
