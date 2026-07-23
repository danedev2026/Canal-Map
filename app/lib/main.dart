import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'attribution.dart';
import 'routing.dart';
import 'stoppages.dart';

void main() => runApp(const CanalMapApp());

/// Single source of truth for POI types: drives the map circle colours, the
/// legend, and the tap info-sheet so they can never drift apart.
class PoiType {
  const PoiType(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;
}

const Map<String, PoiType> kPoiTypes = {
  'lock': PoiType('Lock', Color(0xFFC0392B), Icons.lock),
  'water_point': PoiType('Water point', Color(0xFF2980B9), Icons.water_drop),
  'sanitary': PoiType('Elsan / sanitary', Color(0xFF27AE60), Icons.wc),
  'pumpout': PoiType('Pump-out', Color(0xFF8E44AD), Icons.plumbing),
  'refuse': PoiType('Refuse disposal', Color(0xFF7F8C8D), Icons.delete),
  'pub': PoiType('Pub', Color(0xFFE67E22), Icons.sports_bar),
};

const _defaultPoiColor = Color(0xFF555555);

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

  // Routing (v1.1). Graph loaded lazily the first time route mode is used.
  RouteGraph? _graph;
  bool _routeMode = false;
  bool _routing = false;
  LatLng? _routeStart;
  LatLng? _routeEnd;
  RouteResult? _route;
  String? _routeError;

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

      final glyphsPath = await _prepareGlyphs(dir);

      final indexRaw = await rootBundle.loadString('assets/search_index.json');
      final entries = (jsonDecode(indexRaw) as List)
          .map((e) => SearchEntry.fromJson(e as Map<String, dynamic>))
          .toList();

      setState(() {
        _searchEntries = entries;
        _styleJson = _buildStyle(dest.path, glyphsPath);
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  /// Copy the bundled font glyphs into app storage so MapLibre can render text
  /// labels entirely offline (no glyph server — keeps the £0 constraint).
  Future<String> _prepareGlyphs(Directory dir) async {
    const ranges = ['0-255', '256-511', '512-767', '768-1023'];
    final fontDir = Directory('${dir.path}/glyphs/OpenSans-Regular');
    if (!await fontDir.exists()) await fontDir.create(recursive: true);
    for (final r in ranges) {
      final f = File('${fontDir.path}/$r.pbf');
      final bytes = await rootBundle.load('assets/glyphs/OpenSans-Regular/$r.pbf');
      if (!await f.exists() || await f.length() != bytes.lengthInBytes) {
        await f.writeAsBytes(
            bytes.buffer.asUint8List(0, bytes.lengthInBytes), flush: true);
      }
    }
    return '${dir.path}/glyphs';
  }

  /// MapLibre style referencing the local PMTiles via the pmtiles:// protocol.
  /// source-layers `network` / `features` match the tile layers we built in
  /// the Python pipeline.
  String _buildStyle(String pmtilesPath, String glyphsPath) => '''
{
  "version": 8,
  "glyphs": "file://$glyphsPath/{fontstack}/{range}.pbf",
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
      "id": "tidal",
      "type": "line",
      "source": "canal",
      "source-layer": "network",
      "filter": ["==", ["get", "tidal"], 1],
      "layout": { "line-cap": "butt", "line-join": "round" },
      "paint": {
        "line-color": "#e65100",
        "line-width": [
          "interpolate", ["linear"], ["zoom"],
          6, 1.0,
          11, 2.6,
          16, 6.0
        ],
        "line-dasharray": [2, 2]
      }
    },
    {
      "id": "places",
      "type": "symbol",
      "source": "canal",
      "source-layer": "places",
      "minzoom": 8,
      "filter": ["step", ["zoom"],
        ["match", ["get", "type"], ["city", "town"], true, false],
        11, true
      ],
      "layout": {
        "text-field": ["get", "name"],
        "text-font": ["OpenSans-Regular"],
        "text-size": ["match", ["get", "type"],
          "city", 15, "town", 13, "suburb", 12, 11],
        "text-max-width": 8,
        "symbol-sort-key": ["match", ["get", "type"],
          "city", 1, "town", 2, "suburb", 3, "village", 4, 5]
      },
      "paint": {
        "text-color": "#5a6b78",
        "text-halo-color": "#ffffff",
        "text-halo-width": 1.6
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

    await _addPoiLayer(controller);
    await controller.addGeoJsonSource(_stoppagesSourceId, result.data.toGeoJson());
    await _addStoppageLayer(controller);

    // Empty route layers, updated on demand when a route is computed.
    await controller.addGeoJsonSource('route', _emptyFc());
    await controller.addLineLayer(
      'route', 'route-line',
      const LineLayerProperties(
        lineColor: '#6a1b9a',
        lineWidth: 5.0,
        lineOpacity: 0.85,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      enableInteraction: false,
    );
    await controller.addGeoJsonSource('route-ends', _emptyFc());
    await controller.addCircleLayer(
      'route-ends', 'route-ends-layer',
      CircleLayerProperties(
        circleRadius: 9.0,
        circleColor: [
          'match', ['get', 'role'], 'start', '#2e7d32', 'end', '#c62828', '#000000',
        ],
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: 2.5,
      ),
      enableInteraction: false,
    );
  }

  Map<String, dynamic> _emptyFc() => {'type': 'FeatureCollection', 'features': []};

  /// Render a Material icon glyph to a PNG (white disc + coloured ring + glyph)
  /// so POIs read clearly on the map — no bundled image assets needed.
  Future<Uint8List> _renderIcon(IconData icon, Color color, {int px = 88}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final c = px / 2.0;
    canvas.drawCircle(Offset(c, c), c - 4, Paint()..color = Colors.white);
    canvas.drawCircle(
      Offset(c, c), c - 4,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = px * 0.06,
    );
    final tp = TextPainter(textDirection: TextDirection.ltr);
    tp.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: px * 0.5,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: color,
      ),
    );
    tp.layout();
    tp.paint(canvas, Offset(c - tp.width / 2, c - tp.height / 2));
    final img = await recorder.endRecording().toImage(px, px);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// Register a rendered icon per POI type, then a symbol layer keyed by `type`.
  /// Collision detection (iconAllowOverlap:false) declutters at low zoom.
  Future<void> _addPoiLayer(MapLibreMapController controller) async {
    for (final e in kPoiTypes.entries) {
      await controller.addImage('poi_${e.key}', await _renderIcon(e.value.icon, e.value.color));
    }
    await controller.addImage('poi_default', await _renderIcon(Icons.place, _defaultPoiColor));

    final iconMatch = <dynamic>['match', ['get', 'type']];
    for (final k in kPoiTypes.keys) {
      iconMatch..add(k)..add('poi_$k');
    }
    iconMatch.add('poi_default');

    await controller.addSymbolLayer(
      'canal', _featuresLayerId,
      SymbolLayerProperties(
        iconImage: iconMatch,
        iconSize: ['interpolate', ['linear'], ['zoom'], 8, 0.38, 13, 0.60, 16, 0.82],
        // Collision handles decluttering; stoppages (below) reserve space first.
        iconAllowOverlap: false,
        // Names only once zoomed in, so the overview stays clean.
        textField: ['step', ['zoom'], '', 14, ['get', 'name']],
        textFont: ['OpenSans-Regular'],
        textSize: 11.0,
        textOffset: [0, 1.3],
        textAnchor: 'top',
        textOptional: true, // keep the icon even if the label can't fit
        textColor: '#37474f',
        textHaloColor: '#ffffff',
        textHaloWidth: 1.4,
      ),
      sourceLayer: 'features',
      // Bridges get their own number-label layer below.
      filter: ['!=', ['get', 'type'], 'bridge'],
      // Let taps fall through to onMapClick — otherwise the plugin swallows
      // them as feature-interactions and taps ON a marker do nothing.
      enableInteraction: false,
    );

    // Numbered canal bridges: just the number, close in. Boaters navigate by
    // these ("moor above Bridge 42"), so no icon — the number is the label.
    await controller.addSymbolLayer(
      'canal', 'bridges',
      SymbolLayerProperties(
        textField: ['get', 'ref'],
        textFont: ['OpenSans-Regular'],
        textSize: 11.0,
        textColor: '#5d4037',
        textHaloColor: '#ffffff',
        textHaloWidth: 1.6,
      ),
      sourceLayer: 'features',
      filter: ['==', ['get', 'type'], 'bridge'],
      minzoom: 13,
      enableInteraction: false,
    );
  }

  /// Stoppages as a symbol layer: always drawn (safety info), but they occupy
  /// collision space so POI icons move out of the way instead of overlapping.
  Future<void> _addStoppageLayer(MapLibreMapController controller) async {
    const states = <String, Color>{
      'closed': Color(0xFFD32F2F),
      'restricted': Color(0xFFF9A825),
      'advisory': Color(0xFF1976D2),
    };
    for (final e in states.entries) {
      await controller.addImage(
          'stop_${e.key}', await _renderIcon(Icons.warning_rounded, e.value));
    }
    final match = <dynamic>['match', ['get', 'state']];
    for (final k in states.keys) {
      match..add(k)..add('stop_$k');
    }
    match.add('stop_closed');

    await controller.addSymbolLayer(
      _stoppagesSourceId, _stoppagesLayerId,
      SymbolLayerProperties(
        iconImage: match,
        iconSize: ['interpolate', ['linear'], ['zoom'], 8, 0.44, 13, 0.66, 16, 0.9],
        iconAllowOverlap: true, // closures must always be visible
        iconIgnorePlacement: false, // ...but still block POI icons
      ),
      enableInteraction: false,
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

  // --- Routing (v1.1) -------------------------------------------------------

  Future<void> _toggleRouteMode() async {
    if (_routeMode) {
      await _exitRouteMode();
      return;
    }
    setState(() {
      _routeMode = true;
      _routeError = null;
    });
    _graph ??= await RouteGraph.load('assets/routing.graph');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('Tap a start point, then a destination'),
      ));
    }
  }

  Future<void> _exitRouteMode() async {
    setState(() {
      _routeMode = false;
      _routeStart = null;
      _routeEnd = null;
      _route = null;
      _routeError = null;
    });
    await _controller?.setGeoJsonSource('route', _emptyFc());
    await _controller?.setGeoJsonSource('route-ends', _emptyFc());
  }

  Future<void> _handleRouteTap(LatLng p) async {
    if (_routeStart == null || _route != null || _routeError != null) {
      // Start fresh: first tap (or a tap after a completed route) sets start.
      setState(() {
        _routeStart = p;
        _routeEnd = null;
        _route = null;
        _routeError = null;
      });
      await _drawRouteEnds();
      return;
    }
    // Second tap sets the destination and computes.
    setState(() {
      _routeEnd = p;
      _routing = true;
    });
    await _drawRouteEnds();

    final graph = _graph;
    final result = graph?.route(_routeStart!, _routeEnd!);
    if (!mounted) return;
    setState(() {
      _route = result;
      _routeError = result == null ? 'No through route found' : null;
      _routing = false;
    });
    await _controller?.setGeoJsonSource('route', {
      'type': 'FeatureCollection',
      'features': result == null
          ? []
          : [
              {
                'type': 'Feature',
                'geometry': {
                  'type': 'LineString',
                  'coordinates':
                      result.polyline.map((p) => [p.longitude, p.latitude]).toList(),
                },
              }
            ],
    });
  }

  Future<void> _drawRouteEnds() async {
    final feats = <Map<String, dynamic>>[];
    void add(LatLng? p, String role) {
      if (p == null) return;
      feats.add({
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [p.longitude, p.latitude]},
        'properties': {'role': role},
      });
    }

    add(_routeStart, 'start');
    add(_routeEnd, 'end');
    await _controller?.setGeoJsonSource(
        'route-ends', {'type': 'FeatureCollection', 'features': feats});
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

    if (_routeMode) {
      await _handleRouteTap(latLng);
      return;
    }

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
    // MapLibre uses 512px tiles, so metres/pixel is half the classic 256px
    // figure. Getting this wrong made the tap target twice the intended size.
    final metresPerPixel = 156543.03392 *
        math.cos(latLng.latitude * math.pi / 180) /
        math.pow(2, zoom) /
        2;
    // ~22px ≈ twice the marker's radius: comfortable to hit, but taps well
    // away from a stoppage no longer select it.
    final thresholdM = 22.0 * metresPerPixel;
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
      return Scaffold(
        backgroundColor: const Color(0xFFeef3f6),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.directions_boat,
                  size: 56, color: Color(0xFF2A6FB0)),
              const SizedBox(height: 16),
              Text('Canal Map', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('Preparing offline map…',
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 24),
              const SizedBox(
                  width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
            ],
          ),
        ),
      );
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
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About & data sources',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AttributionScreen()),
            ),
          ),
        ],
      ),
      // In route mode the summary panel occupies the bottom strip, so lift the
      // buttons clear of it — otherwise they cover the journey figures.
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: _routeMode ? 104 : 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FloatingActionButton.small(
              heroTag: 'route',
              onPressed: _toggleRouteMode,
              tooltip: 'Plan a route',
              backgroundColor: _routeMode ? const Color(0xFF6A1B9A) : null,
              foregroundColor: _routeMode ? Colors.white : null,
              child: Icon(_routeMode ? Icons.close : Icons.directions_boat),
            ),
            const SizedBox(height: 12),
            FloatingActionButton(
              heroTag: 'loc',
              onPressed: _followMe,
              tooltip: 'My location',
              child: Icon(following ? Icons.my_location : Icons.location_searching),
            ),
          ],
        ),
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
          if (_routeMode)
            Align(
              alignment: Alignment.bottomCenter,
              child: _RoutePanel(
                routing: _routing,
                route: _route,
                error: _routeError,
                hasStart: _routeStart != null,
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

class _RoutePanel extends StatelessWidget {
  const _RoutePanel({
    required this.routing,
    required this.route,
    required this.error,
    required this.hasStart,
  });

  final bool routing;
  final RouteResult? route;
  final String? error;
  final bool hasStart;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (routing) {
      body = const Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 12),
        Text('Finding route…'),
      ]);
    } else if (error != null) {
      body = Text(error!, style: const TextStyle(color: Color(0xFFC62828)));
    } else if (route != null) {
      final h = route!.eta.inHours;
      final m = route!.eta.inMinutes % 60;
      final eta = h > 0 ? '${h}h ${m}m' : '${m}m';
      body = Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _stat(context, '${route!.miles.toStringAsFixed(1)} mi', 'distance'),
          _stat(context, '${route!.locks}', 'locks'),
          _stat(context, eta, 'approx time'),
        ],
      );
    } else {
      body = Text(hasStart ? 'Tap a destination' : 'Tap a start point',
          style: Theme.of(context).textTheme.bodyMedium);
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Card(
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: body,
          ),
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String label) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

class _DashSwatch extends StatelessWidget {
  const _DashSwatch({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(15, 3), painter: _DashPainter(color));
}

class _DashPainter extends CustomPainter {
  const _DashPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.butt;
    const dash = 4.0, gap = 3.0;
    var x = 0.0;
    final y = size.height / 2;
    while (x < size.width) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + dash, size.width), y), p);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashPainter old) => old.color != color;
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
                      Icon(e.value.icon, size: 15, color: e.value.color),
                      const SizedBox(width: 7),
                      Text(e.value.label,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _DashSwatch(color: Color(0xFFE65100)),
                    const SizedBox(width: 7),
                    Text('Tidal — hazard',
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
