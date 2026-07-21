import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// One navigation notice/closure (Bucket 2 data). Positioned by lat/lon that
/// the pipeline/GitHub Action attaches when producing stoppages.json.
class Stoppage {
  const Stoppage({
    required this.id,
    required this.title,
    required this.type,
    required this.reason,
    required this.waterway,
    required this.state,
    required this.start,
    required this.end,
    required this.lat,
    required this.lon,
    required this.url,
  });

  final String id;
  final String title;
  final String type; // Navigation Closure / Restriction / Advice ...
  final String reason;
  final String waterway;
  final String state; // closed | restricted | advisory
  final String start;
  final String end;
  final double lat;
  final double lon;
  final String url;

  factory Stoppage.fromJson(Map<String, dynamic> j) => Stoppage(
        id: '${j['id'] ?? ''}',
        title: '${j['title'] ?? 'Notice'}',
        type: '${j['type'] ?? ''}',
        reason: '${j['reason'] ?? ''}',
        waterway: '${j['waterway'] ?? ''}',
        state: '${j['state'] ?? 'closed'}',
        start: '${j['start'] ?? ''}',
        end: '${j['end'] ?? ''}',
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        url: '${j['url'] ?? ''}',
      );

  Map<String, dynamic> toFeature() => {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [lon, lat],
        },
        'properties': {
          'id': id,
          'title': title,
          'type': type,
          'reason': reason,
          'waterway': waterway,
          'state': state,
          'start': start,
          'end': end,
          'url': url,
        },
      };
}

class Stoppages {
  const Stoppages(this.updated, this.items);
  final DateTime? updated;
  final List<Stoppage> items;

  static Stoppages parse(String jsonStr) {
    final doc = jsonDecode(jsonStr) as Map<String, dynamic>;
    final updated = DateTime.tryParse('${doc['updated'] ?? ''}');
    final items = ((doc['stoppages'] as List?) ?? [])
        .map((e) => Stoppage.fromJson(e as Map<String, dynamic>))
        .toList();
    return Stoppages(updated, items);
  }

  Map<String, dynamic> toGeoJson() => {
        'type': 'FeatureCollection',
        'features': items.map((s) => s.toFeature()).toList(),
      };
}

class StoppagesResult {
  const StoppagesResult(this.data, this.fromNetwork);
  final Stoppages data;
  final bool fromNetwork;

  /// "Notices updated today" / "…3 days ago" (+ "· offline" when served from
  /// the cached/bundled copy rather than a fresh fetch).
  String freshnessLabel(DateTime now) {
    final updated = data.updated;
    String age;
    if (updated == null) {
      age = 'unknown date';
    } else {
      final days = now.difference(updated).inDays;
      age = days <= 0 ? 'today' : (days == 1 ? '1 day ago' : '$days days ago');
    }
    return fromNetwork ? 'Notices updated $age' : 'Notices updated $age · offline';
  }
}

/// The two-bucket fetch: try the network, else the last saved copy, else the
/// bundled fixture. The map ALWAYS has something to render — network is only
/// ever a background top-up and never blocks the UI.
class StoppagesService {
  static Future<StoppagesResult> load({
    required String bundledAsset,
    String? url,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final cache = File('${dir.path}/stoppages.json');

    // 1) Network (only if a host is configured).
    if (url != null && url.isNotEmpty) {
      try {
        final resp =
            await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) {
          final data = Stoppages.parse(resp.body);
          await cache.writeAsString(resp.body, flush: true); // overwrite cache
          return StoppagesResult(data, true);
        }
      } catch (_) {
        // fall through to cache/bundle — offline is expected, not an error
      }
    }

    // 2) Last saved copy.
    if (await cache.exists()) {
      try {
        return StoppagesResult(Stoppages.parse(await cache.readAsString()), false);
      } catch (_) {/* corrupt cache → bundle */}
    }

    // 3) Bundled fixture (guarantees offline-first works on a fresh install).
    return StoppagesResult(
        Stoppages.parse(await rootBundle.loadString(bundledAsset)), false);
  }
}
