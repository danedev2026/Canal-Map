import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'stoppages.dart';

void main() => runApp(const CanalMapApp());

/// Single source of truth for POI types: drives the map circle colours, the
/// legend, and the tap info-sheet so they can never drift apart.
class PoiType {
  const PoiType(this.label, this.color);
  final String label;
  final Color color;
}

const Map<String, PoiType> kPoiTypes = {
  'lock': PoiType('Lock', Color(0xFFC0392B)),
  'water_point': PoiType('Water point', Color(0xFF2980B9)),
  'sanitary': PoiType('Elsan / sanitary', Color(0xFF27AE60)),
  'pumpout': PoiType('Pump-out', Color(0xFF8E44AD)),
  'refuse': PoiType('Refuse disposal', Color(0xFF7F8C8D)),
  'pub': PoiType('Pub', Color(0xFFE67E22)),
};

const _defaultPoiColor = Color(0xFF555555);

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

class CanalMapApp extends StatelessWidget {
  const CanalMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Canal Map',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2A6FB0)),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // Opens on the Midlands canal heartland (Birmingham) — the densest part of
  // the nationwide network. Users pan/search from here.
  static const _initialCamera =
      CameraPosition(target: LatLng(52.48, -1.90), zoom: 9);

  static const _featuresLayerId = 'features';
  static const _stoppagesLayerId = 'stoppages-layer';
  static const _stoppagesSourceId = 'stoppages';

  // Bucket 2: the ONLY networked file — the live CRT stoppages feed, produced
  // daily by the GitHub Action. Fetched with offline fallback to the bundled
  // snapshot, so the map always works.
  static const String _stoppagesUrl =
      'https://raw.githubusercontent.com/danedev2026/Canal-Map/main/data/stoppages.json';

  MapLibreMapController? _controller;
  String? _styleJson;
  String? _error;

  // Location state. GPS works offline; the dot only shows once granted.
  bool _locationEnabled = false;
  MyLocationTrackingMode _tracking = MyLocationTrackingMode.none;

  // In-memory search index (named POIs + waterways). No database.
  List<SearchEntry> _searchEntries = const [];

  // Live stoppages overlay (Bucket 2) + a freshness label for the UI.
  List<Stoppage> _stoppages = const [];
  String? _stoppagesFreshness;

  @override
  void initState() {
    super.initState();
    _prepareOfflineBasemap();
  }

  /// Bucket 1: copy the bundled basemap into app storage once, then point
  /// MapLibre at the LOCAL file. Nothing here ever touches the network.
  Future<void> _prepareOfflineBasemap() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/basemap.pmtiles');

      // Copy from assets on first run (or if the bundled copy changed size,
      // which is our cheap "new app release shipped fresh tiles" signal).
      final bundled = await rootBundle.load('assets/basemap.pmtiles');
      final bundledLen = bundled.lengthInBytes;
      if (!await dest.exists() || await dest.length() != bundledLen) {
        await dest.writeAsBytes(
          bundled.buffer.asUint8List(0, bundledLen),
          flush: true,
        );
      }

      final indexRaw = await rootBundle.loadString('assets/search_index.json');
      final entries = (jsonDecode(indexRaw) as List)
          .map((e) => SearchEntry.fromJson(e as Map<String, dynamic>))
          .toList();

      setState(() {
        _searchEntries = entries;
        _styleJson = _buildStyle(dest.path);
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  /// MapLibre `match` expression colouring feature circles by their `type`.
  String _circleColorExpr() {
    final buf = StringBuffer('["match", ["get", "type"]');
    kPoiTypes.forEach((key, v) => buf.write(', "$key", "${_hex(v.color)}"'));
    buf.write(', "${_hex(_defaultPoiColor)}"]');
    return buf.toString();
  }

  /// MapLibre style referencing the local PMTiles via the pmtiles:// protocol.
  /// source-layers `network` / `features` match the tile layers we built in
  /// the Python pipeline.
  String _buildStyle(String pmtilesPath) => '''
{
  "version": 8,
  "sources": {
    "canal": {
      "type": "vector",
      "attribution": "© OpenStreetMap contributors (ODbL); Canal & River Trust",
      "url": "pmtiles://file://$pmtilesPath"
    }
  },
  "layers": [
    {
      "id": "background",
      "type": "background",
      "paint": { "background-color": "#eef3f6" }
    },
    {
      "id": "waterway",
      "type": "line",
      "source": "canal",
      "source-layer": "network",
      "layout": { "line-cap": "round", "line-join": "round" },
      "paint": {
        "line-color": [
          "match", ["get", "waterway"],
          "canal", "#2a6fb0",
          "river", "#3a8fd0",
          "#3a8fd0"
        ],
        "line-width": [
          "interpolate", ["linear"], ["zoom"],
          6, 0.6,
          11, 1.8,
          16, 4.5
        ]
      }
    },
    {
      "id": "$_featuresLayerId",
      "type": "circle",
      "source": "canal",
      "source-layer": "features",
      "paint": {
        "circle-radius": [
          "interpolate", ["linear"], ["zoom"],
          9, 3,
          13, 5.5,
          16, 8
        ],
        "circle-color": ${_circleColorExpr()},
        "circle-stroke-color": "#ffffff",
        "circle-stroke-width": 1.5,
        "circle-opacity": 0.95
      }
    }
  ]
}
''';

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
  }

  /// Runs once the map style is ready: load stoppages (network → cache →
  /// bundle) and draw them as an overlay. Never blocks the map.
  Future<void> _onStyleLoaded() async {
    final result = await StoppagesService.load(
      bundledAsset: 'assets/stoppages.json',
      url: _stoppagesUrl,
    );
    if (!mounted) return;
    setState(() {
      _stoppages = result.data.items;
      _stoppagesFreshness = result.freshnessLabel(DateTime.now());
    });

    final controller = _controller;
    if (controller == null) return;
    await controller.addGeoJsonSource(_stoppagesSourceId, result.data.toGeoJson());
    await controller.addCircleLayer(
      _stoppagesSourceId,
      _stoppagesLayerId,
      CircleLayerProperties(
        circleRadius: [
          'interpolate', ['linear'], ['zoom'], 8, 6.0, 14, 9.0, 16, 12.0,
        ],
        circleColor: [
          'match', ['get', 'state'],
          'closed', '#d32f2f',
          'restricted', '#f9a825',
          'advisory', '#1976d2',
          '#d32f2f',
        ],
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: 2.5,
        circleOpacity: 0.9,
      ),
    );
  }

  Future<bool> _ensureLocationPermission() async {
    final status = await Permission.locationWhenInUse.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Location is off. Enable it in Settings to use it.'),
        ));
      }
      return false;
    }
    return (await Permission.locationWhenInUse.request()).isGranted;
  }

  /// Follow-me: turn on the GPS dot (once permitted) and track the user.
  Future<void> _followMe() async {
    if (!await _ensureLocationPermission()) return;
    if (!mounted) return;
    setState(() {
      _locationEnabled = true;
      _tracking = MyLocationTrackingMode.tracking;
    });
    // If the map was already showing the dot, nudge tracking back on.
    await _controller?.updateMyLocationTrackingMode(
      MyLocationTrackingMode.tracking,
    );
  }

  // A pan/zoom gesture cancels follow-me; reflect that in the FAB icon.
  void _onCameraTrackingDismissed() {
    if (mounted) setState(() => _tracking = MyLocationTrackingMode.none);
  }

  Future<void> _openSearch() async {
    // "Near me" needs the current position; null if location isn't on yet.
    final here = _locationEnabled
        ? await _controller?.requestMyLocationLatLng()
        : null;
    if (!mounted) return;

    final picked = await showSearch<SearchEntry?>(
      context: context,
      delegate: PoiSearchDelegate(_searchEntries, here),
    );
    if (picked == null) return;

    final target = LatLng(picked.lat, picked.lon);
    await _controller?.animateCamera(CameraUpdate.newLatLngZoom(target, 15));
    if (picked.type != 'waterway') {
      _showFeatureSheet({'type': picked.type, 'name': picked.name});
    }
  }

  /// Tap → query the feature circles under the touch (with a little padding
  /// for fat fingers) → show details. Purely local; no network.
  Future<void> _onMapClick(math.Point<double> point, LatLng latLng) async {
    final controller = _controller;
    if (controller == null) return;

    const pad = 22.0;
    final rect = Rect.fromLTRB(
      point.x - pad,
      point.y - pad,
      point.x + pad,
      point.y + pad,
    );

    // Stoppages sit on top and take priority. They're a runtime-added GeoJSON
    // layer (queryRenderedFeatures is unreliable for those), so hit-test in
    // geographic space against the in-memory list, with a zoom-scaled pixel
    // tolerance. Avoids mixing screen-coordinate scales across devices.
    final zoom = controller.cameraPosition?.zoom ?? 14.0;
    final metresPerPixel = 156543.03392 *
        math.cos(latLng.latitude * math.pi / 180) /
        math.pow(2, zoom);
    // Generous tap target (~44px) — closures matter and the marker is bold.
    final thresholdM = 44.0 * metresPerPixel;
    Stoppage? hit;
    var hitDist = double.infinity;
    for (final s in _stoppages) {
      final d = _haversineMetres(
          latLng.latitude, latLng.longitude, s.lat, s.lon);
      if (d <= thresholdM && d < hitDist) {
        hit = s;
        hitDist = d;
      }
    }
    if (hit != null) {
      if (mounted) {
        _showStoppageSheet(
            Map<String, dynamic>.from(hit.toFeature()['properties'] as Map));
      }
      return;
    }

    final features = await controller.queryRenderedFeaturesInRect(
      rect, [_featuresLayerId], null);
    if (features.isEmpty || !mounted) return;
    _showFeatureSheet(_propsOf(features.first));
  }

  Map<String, dynamic> _propsOf(dynamic feature) =>
      (feature is Map && feature['properties'] is Map)
          ? Map<String, dynamic>.from(feature['properties'] as Map)
          : <String, dynamic>{};

  void _showStoppageSheet(Map<String, dynamic> p) {
    final state = (p['state'] ?? '').toString();
    final color = switch (state) {
      'restricted' => const Color(0xFFF9A825),
      'advisory' => const Color(0xFF1976D2),
      _ => const Color(0xFFD32F2F),
    };
    final dates = [p['start'], p['end']]
        .map((e) => (e ?? '').toString())
        .where((e) => e.isNotEmpty)
        .join(' → ');

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: color, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '${p['type'] ?? 'Notice'}'.toUpperCase(),
                    style: Theme.of(ctx)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: color, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('${p['title'] ?? ''}',
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              if ('${p['waterway'] ?? ''}'.isNotEmpty)
                _kv(ctx, 'Waterway', '${p['waterway']}'),
              if ('${p['reason'] ?? ''}'.isNotEmpty)
                _kv(ctx, 'Reason', '${p['reason']}'),
              if (dates.isNotEmpty) _kv(ctx, 'Dates', dates),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(BuildContext ctx, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: RichText(
          text: TextSpan(
            style: Theme.of(ctx).textTheme.bodyMedium,
            children: [
              TextSpan(
                  text: '$k: ',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: v),
            ],
          ),
        ),
      );

  void _showFeatureSheet(Map<String, dynamic> props) {
    final typeKey = (props['type'] ?? '').toString();
    final meta = kPoiTypes[typeKey];
    final name = (props['name'] ?? '').toString().trim();
    final sourceLabel = switch ((props['source'] ?? '').toString()) {
      'crt' => 'Canal & River Trust',
      'osm' => 'OpenStreetMap',
      _ => null,
    };

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: meta?.color ?? _defaultPoiColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    meta?.label ?? (typeKey.isEmpty ? 'Feature' : typeKey),
                    style: Theme.of(ctx).textTheme.labelLarge,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                name.isEmpty ? 'Unnamed ${meta?.label.toLowerCase() ?? 'feature'}' : name,
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              if (sourceLabel != null) ...[
                const SizedBox(height: 12),
                Text('Source: $sourceLabel',
                    style: Theme.of(ctx).textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load basemap:\n$_error',
                textAlign: TextAlign.center),
          ),
        ),
      );
    }
    if (_styleJson == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final following = _tracking != MyLocationTrackingMode.none;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Canal Map'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search places & waterways',
            onPressed: _searchEntries.isEmpty ? null : _openSearch,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _followMe,
        tooltip: 'My location',
        child: Icon(following ? Icons.my_location : Icons.location_searching),
      ),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: _styleJson!,
            initialCameraPosition: _initialCamera,
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onMapClick: _onMapClick,
            myLocationEnabled: _locationEnabled,
            myLocationTrackingMode: _tracking,
            myLocationRenderMode: MyLocationRenderMode.normal,
            onCameraTrackingDismissed: _onCameraTrackingDismissed,
            trackCameraPosition: true,
            compassEnabled: true,
          ),
          const SafeArea(child: _Legend()),
          if (_stoppagesFreshness != null)
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: _FreshnessChip(
                  label: _stoppagesFreshness!,
                  count: _stoppages.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One searchable place: a named POI or a waterway. Loaded from the bundled
/// search_index.json; searched entirely in memory (no database, works offline).
class SearchEntry {
  const SearchEntry(this.name, this.type, this.lat, this.lon);
  final String name;
  final String type;
  final double lat;
  final double lon;

  factory SearchEntry.fromJson(Map<String, dynamic> j) => SearchEntry(
        j['name'] as String,
        j['type'] as String,
        (j['lat'] as num).toDouble(),
        (j['lon'] as num).toDouble(),
      );
}

String _typeLabel(String type) =>
    type == 'waterway' ? 'Waterway' : (kPoiTypes[type]?.label ?? 'Feature');

Color _typeColor(String type) =>
    type == 'waterway' ? const Color(0xFF2A6FB0) : (kPoiTypes[type]?.color ?? _defaultPoiColor);

/// Great-circle distance in metres.
double _haversineMetres(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * 2 * math.asin(math.min(1, math.sqrt(a)));
}

String _formatDistance(double metres) =>
    metres < 1000 ? '${metres.round()} m' : '${(metres / 1000).toStringAsFixed(1)} km';

/// Client-side search over the in-memory index. Empty query shows nearest
/// features (if we have a location) so "near me" falls out for free.
class PoiSearchDelegate extends SearchDelegate<SearchEntry?> {
  PoiSearchDelegate(this.entries, this.here)
      : super(searchFieldLabel: 'Search places & waterways');

  final List<SearchEntry> entries;
  final LatLng? here;

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _resultsList(context);

  @override
  Widget buildSuggestions(BuildContext context) => _resultsList(context);

  Widget _resultsList(BuildContext context) {
    final q = query.trim().toLowerCase();

    if (q.isEmpty) {
      if (here == null) {
        return const _Hint(
            'Type to search, or tap the location button first to see what’s near you.');
      }
      final near = [...entries]..sort((a, b) => _dist(a).compareTo(_dist(b)));
      return _list(context, near.take(30).toList());
    }

    final matches = entries.where((e) => e.name.toLowerCase().contains(q)).toList()
      ..sort((a, b) {
        // Prefix matches first, then alphabetical.
        final ap = a.name.toLowerCase().startsWith(q) ? 0 : 1;
        final bp = b.name.toLowerCase().startsWith(q) ? 0 : 1;
        return ap != bp ? ap - bp : a.name.compareTo(b.name);
      });
    if (matches.isEmpty) return _Hint('No matches for “$query”.');
    return _list(context, matches.take(60).toList());
  }

  double _dist(SearchEntry e) =>
      here == null ? 0 : _haversineMetres(here!.latitude, here!.longitude, e.lat, e.lon);

  Widget _list(BuildContext context, List<SearchEntry> items) {
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final e = items[i];
        return ListTile(
          leading: CircleAvatar(
            radius: 8,
            backgroundColor: _typeColor(e.type),
          ),
          title: Text(e.name),
          subtitle: Text(_typeLabel(e.type)),
          trailing: here == null
              ? null
              : Text(_formatDistance(_dist(e)),
                  style: Theme.of(ctx).textTheme.bodySmall),
          onTap: () => close(ctx, e),
        );
      },
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium),
        ),
      );
}

class _FreshnessChip extends StatelessWidget {
  const _FreshnessChip({required this.label, required this.count});
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Card(
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 16,
                  color: count > 0 ? const Color(0xFFD32F2F) : Colors.grey),
              const SizedBox(width: 6),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$count ${count == 1 ? 'notice' : 'notices'}',
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Card(
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Facilities',
                  style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 6),
              for (final e in kPoiTypes.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          color: e.value.color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.2),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(e.value.label,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
