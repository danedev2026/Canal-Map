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

import 'app_settings.dart';
import 'attribution.dart';
import 'boat_log.dart';
import 'boat_log_screen.dart';
import 'exporter.dart';
import 'popular_routes.dart';
import 'popular_routes_screen.dart';
import 'route_plan_pdf.dart';
import 'routing.dart';
import 'saved_routes.dart';
import 'saved_routes_screen.dart';
import 'settings_screen.dart';
import 'stoppages.dart';
import 'stoppages_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.instance.load();
  runApp(const CanalMapApp());
}

/// Single source of truth for POI types: drives the map circle colours, the
/// legend, and the tap info-sheet so they can never drift apart.
class PoiType {
  const PoiType(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;
}

const Map<String, PoiType> kPoiTypes = {
  // Lock is drawn as a charcoal lock-gate chevron (see _renderLockIcon /
  // _GateIcon), not this padlock glyph — the colour here is the brand charcoal.
  'lock': PoiType('Lock', Color(0xFF37474F), Icons.lock),
  'water_point': PoiType('Water point', Color(0xFF2980B9), Icons.water_drop),
  'sanitary': PoiType('Elsan / sanitary', Color(0xFF27AE60), Icons.wc),
  'pumpout': PoiType('Pump-out', Color(0xFF8E44AD), Icons.plumbing),
  'refuse': PoiType('Refuse disposal', Color(0xFF7F8C8D), Icons.delete),
  'pub': PoiType('Pub', Color(0xFFE67E22), Icons.sports_bar),
  'mooring': PoiType('Mooring', Color(0xFF00897B), Icons.anchor),
};

const _defaultPoiColor = Color(0xFF555555);

class CanalMapApp extends StatelessWidget {
  const CanalMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuild when the user changes theme mode / colour (AppSettings notifies).
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) {
        final s = AppSettings.instance;
        return MaterialApp(
          title: 'Canal Map: UK Waterways',
          debugShowCheckedModeBanner: false,
          theme: s.themeFor(Brightness.light),
          darkTheme: s.themeFor(Brightness.dark),
          themeMode: s.mode,
          home: const MapScreen(),
        );
      },
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
  bool _showPlanned = false; // future/winter stoppages hidden by default

  // Layer toggles (the "Map layers" sheet).
  final Set<String> _hiddenTypes = {};   // facility types hidden
  final Set<String> _hiddenStates = {};  // stoppage severities hidden
  bool _showWinding = true;              // winding-hole overlay

  // Multi-day planning: cruising hours per day (drives day markers + the plan).
  int _hoursPerDay = 6;

  /// Stoppages to draw: current ones by default (planned/future only with the
  /// toggle), minus any severities hidden in the layers sheet.
  List<Stoppage> get _visibleStoppages {
    final now = DateTime.now();
    return _stoppages.where((s) {
      if (_hiddenStates.contains(s.state)) return false;
      if (!_showPlanned) {
        final start = DateTime.tryParse(s.start);
        if (start != null && start.isAfter(now)) return false;
      }
      return true;
    }).toList();
  }

  Map<String, dynamic> _stoppagesFc(List<Stoppage> list) => {
        'type': 'FeatureCollection',
        'features': list.map((s) => s.toFeature()).toList(),
      };

  double _bearing = 0; // map rotation, drives the compass
  bool _satellite = false; // online aerial imagery basemap

  // Dark-map support. Paths kept so the style can be rebuilt when the theme's
  // brightness changes (light ↔ dark map).
  String? _pmtilesPath;
  String? _glyphsPath;
  bool _dark = false;

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
        _pmtilesPath = dest.path;
        _glyphsPath = glyphsPath;
        _styleJson = _buildStyle(dest.path, glyphsPath, _dark);
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
  String _buildStyle(String pmtilesPath, String glyphsPath, bool dark) {
    // Theme-aware palette: a dark map for dark mode, light otherwise. Canals
    // keep a blue identity in both; brightened a touch on the dark background.
    final bg = dark ? '#0e1a1f' : '#eef3f6';
    final canal = dark ? '#4a90d0' : '#2a6fb0';
    final river = dark ? '#5aa6e2' : '#3a8fd0';
    final placeText = dark ? '#9fb3c0' : '#5a6b78';
    final placeHalo = dark ? '#0b151a' : '#ffffff';
    return '''
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
      "paint": { "background-color": "$bg" }
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
          "canal", "$canal",
          "river", "$river",
          "$river"
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
        "text-color": "$placeText",
        "text-halo-color": "$placeHalo",
        "text-halo-width": 1.6
      }
    }
  ]
}
''';
  }

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
    controller.addListener(_onCameraChanged);
  }

  void _onCameraChanged() {
    final b = _controller?.cameraPosition?.bearing ?? 0;
    if ((b - _bearing).abs() > 0.5) setState(() => _bearing = b);
  }

  Future<void> _resetNorth() async {
    await _controller?.animateCamera(CameraUpdate.bearingTo(0));
  }

  /// Current GPS position as (lat, lon), or null if unavailable. Ensures the
  /// location permission and turns the map's location component on.
  Future<(double, double)?> _currentLatLon() async {
    if (!await _ensureLocationPermission()) return null;
    if (mounted) setState(() => _locationEnabled = true);
    final ll = await _controller?.requestMyLocationLatLng();
    return ll == null ? null : (ll.latitude, ll.longitude);
  }

  Future<void> _logMyPosition() async {
    final loc = await _currentLatLon();
    if (!mounted) return;
    if (loc == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No GPS fix yet — try again in a moment.')));
      return;
    }
    final place = _nearestPlaceLabel(loc.$1, loc.$2);
    await BoatLog.add(BoatLogEntry(DateTime.now(), loc.$1, loc.$2, place: place));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(place.isEmpty
              ? 'Position logged to your boat log'
              : 'Logged $place to your boat log')));
    }
  }

  /// A short human label for a position — the nearest named place/waterway in
  /// the search index, e.g. "near Braunston" or "on the Oxford Canal". Empty if
  /// nothing is close. Powers the descriptive boat log. Purely local.
  String _nearestPlaceLabel(double lat, double lon) {
    SearchEntry? bestPlace, bestWaterway;
    double dPlace = double.infinity, dWaterway = double.infinity;
    for (final e in _searchEntries) {
      final d = _haversineMetres(lat, lon, e.lat, e.lon);
      if (e.type == 'waterway') {
        if (d < dWaterway) { dWaterway = d; bestWaterway = e; }
      } else {
        if (d < dPlace) { dPlace = d; bestPlace = e; }
      }
    }
    final parts = <String>[];
    if (bestPlace != null && dPlace <= 2000) parts.add('near ${bestPlace.name}');
    if (bestWaterway != null && dWaterway <= 400) {
      parts.add('on the ${bestWaterway.name}');
    }
    return parts.join(', ');
  }

  Future<void> _toggleSatellite() async {
    setState(() => _satellite = !_satellite);
    await _controller?.setLayerVisibility('satellite', _satellite);
    if (mounted && _satellite) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        duration: Duration(seconds: 3),
        content: Text('Aerial imagery needs a data connection; '
            'the map still works offline without it.'),
      ));
    }
  }

  void _openMenu(String v) {
    switch (v) {
      case 'satellite':
        _toggleSatellite();
      case 'log':
        _logMyPosition();
      case 'logbook':
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => BoatLogScreen(
                getLocation: _currentLatLon, nearestPlace: _nearestPlaceLabel)));
      case 'notices':
        _openStoppagesList();
      case 'saved':
        _openSavedRoutes();
      case 'popular':
        _openPopularRoutes();
      case 'settings':
        Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()));
      case 'about':
        Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AttributionScreen()));
    }
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

    await _addSatellite(controller);
    await _addPoiLayer(controller);
    await _addWindingLayer(controller);
    await controller.addGeoJsonSource(
        _stoppagesSourceId, _stoppagesFc(_visibleStoppages));
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
    await _addDayMarkerLayers(controller);

    // A style reload (e.g. switching light/dark) wipes runtime layers, so
    // restore whatever the user had on: a drawn route, its ends + day markers.
    if (_route != null) {
      await controller.setGeoJsonSource('route', _routeLineFc(_route!));
      await _drawRouteEnds();
      await _drawDayMarkers(_route!);
    }
  }

  Map<String, dynamic> _routeLineFc(RouteResult r) => {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'geometry': {
              'type': 'LineString',
              'coordinates':
                  r.polyline.map((q) => [q.longitude, q.latitude]).toList(),
            },
          }
        ],
      };

  Map<String, dynamic> _emptyFc() => {'type': 'FeatureCollection', 'features': []};

  /// Optional online aerial imagery (Esri World Imagery — free, no API key).
  /// Added beneath the network, hidden by default; toggled from the menu. Only
  /// loads when online, so the offline-first core is unaffected.
  Future<void> _addSatellite(MapLibreMapController controller) async {
    await controller.addSource(
      'satellite',
      const RasterSourceProperties(
        tiles: [
          'https://server.arcgisonline.com/ArcGIS/rest/services/'
              'World_Imagery/MapServer/tile/{z}/{y}/{x}'
        ],
        tileSize: 256,
        maxzoom: 19,
        attribution: 'Imagery © Esri, Maxar, Earthstar Geographics',
      ),
    );
    await controller.addRasterLayer(
      'satellite', 'satellite',
      const RasterLayerProperties(),
      belowLayerId: 'waterway', // canals + POIs stay on top
    );
    // Preserve the user's choice across style reloads (theme switches).
    await controller.setLayerVisibility('satellite', _satellite);
  }

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

  /// The lock marker: a white disc + coloured ring + two gate chevrons (the
  /// motif from the app icon) — reads as a canal lock, not a padlock.
  Future<Uint8List> _renderLockIcon(Color color, {int px = 88}) async {
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
    final gate = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = px * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = px * 0.22, h = px * 0.12;
    for (final cy in [c - px * 0.10, c + px * 0.14]) {
      canvas.drawPath(
        Path()
          ..moveTo(c - w, cy + h)
          ..lineTo(c, cy - h)
          ..lineTo(c + w, cy + h),
        gate,
      );
    }
    final img = await recorder.endRecording().toImage(px, px);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// Register a rendered icon per POI type, then a symbol layer keyed by `type`.
  /// Collision detection (iconAllowOverlap:false) declutters at low zoom.
  Future<void> _addPoiLayer(MapLibreMapController controller) async {
    for (final e in kPoiTypes.entries) {
      final bytes = e.key == 'lock'
          ? await _renderLockIcon(e.value.color)
          : await _renderIcon(e.value.icon, e.value.color);
      await controller.addImage('poi_${e.key}', bytes);
    }
    await controller.addImage('poi_default', await _renderIcon(Icons.place, _defaultPoiColor));
    await controller.addImage(
        'poi_winding', await _renderIcon(Icons.refresh, const Color(0xFF3949AB)));

    final iconMatch = <dynamic>['match', ['get', 'type']];
    for (final k in kPoiTypes.keys) {
      iconMatch..add(k)..add('poi_$k');
    }
    iconMatch.add('poi_default');

    await controller.addSymbolLayer(
      'canal', _featuresLayerId,
      SymbolLayerProperties(
        iconImage: iconMatch,
        iconSize: ['interpolate', ['linear'], ['zoom'], 8, 0.50, 13, 0.80, 16, 1.05],
        // Collision handles decluttering; stoppages (below) reserve space first.
        iconAllowOverlap: false,
        // Names only once zoomed in, so the overview stays clean.
        textField: ['step', ['zoom'], '', 14, ['get', 'name']],
        textFont: ['OpenSans-Regular'],
        textSize: 11.0,
        textOffset: [0, 1.3],
        textAnchor: 'top',
        textOptional: true, // keep the icon even if the label can't fit
        textColor: _dark ? '#d7e0e6' : '#37474f',
        textHaloColor: _dark ? '#0b151a' : '#ffffff',
        textHaloWidth: 1.4,
      ),
      sourceLayer: 'features',
      // Bridges get their own number-label layer below; hidden facility types
      // (from the layers sheet) are filtered out here too.
      filter: _featuresFilter(),
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
        textColor: _dark ? '#c9a97e' : '#5d4037',
        textHaloColor: _dark ? '#0b151a' : '#ffffff',
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
        iconSize: ['interpolate', ['linear'], ['zoom'], 8, 0.58, 13, 0.88, 16, 1.15],
        iconAllowOverlap: true, // closures must always be visible
        iconIgnorePlacement: false, // ...but still block POI icons
      ),
      enableInteraction: false,
    );
  }

  // --- Layer toggles (the "Map layers" sheet) -------------------------------

  /// Features-layer filter: never show bridges here, and drop any facility types
  /// the user has hidden.
  List<dynamic> _featuresFilter() {
    final base = <dynamic>['!=', ['get', 'type'], 'bridge'];
    if (_hiddenTypes.isEmpty) return base;
    return [
      'all', base,
      ['!', ['in', ['get', 'type'], ['literal', _hiddenTypes.toList()]]],
    ];
  }

  Future<void> _applyFeatureFilter() async =>
      _controller?.setFilter(_featuresLayerId, _featuresFilter());

  /// Rebuild the stoppages overlay from the currently-visible set (respects the
  /// planned toggle + hidden severities).
  Future<void> _refreshStoppages() async => _controller?.setGeoJsonSource(
      _stoppagesSourceId, _stoppagesFc(_visibleStoppages));

  List<LatLng> _windingPts = const [];

  /// Winding holes (turning points) — a bundled overlay, toggleable.
  Future<void> _addWindingLayer(MapLibreMapController controller) async {
    try {
      final raw = await rootBundle.loadString('assets/winding_holes.json');
      final pts = (jsonDecode(raw) as List).cast<List>();
      _windingPts = [
        for (final p in pts) LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()),
      ];
      await controller.addGeoJsonSource('winding', {
        'type': 'FeatureCollection',
        'features': [
          for (final p in pts)
            {
              'type': 'Feature',
              'geometry': {'type': 'Point', 'coordinates': [
                (p[0] as num).toDouble(), (p[1] as num).toDouble()]},
              'properties': const {'winding': 1},
            }
        ],
      });
      await controller.addSymbolLayer(
        'winding', 'winding-layer',
        SymbolLayerProperties(
          iconImage: 'poi_winding',
          iconSize: ['interpolate', ['linear'], ['zoom'], 8, 0.45, 13, 0.72, 16, 0.95],
          iconAllowOverlap: false,
        ),
        enableInteraction: false,
      );
      await controller.setLayerVisibility('winding-layer', _showWinding);
    } catch (_) {/* overlay is optional */}
  }

  /// Numbered pills at each overnight boundary of a multi-day route.
  Future<void> _addDayMarkerLayers(MapLibreMapController controller) async {
    await controller.addGeoJsonSource('route-days', _emptyFc());
    await controller.addCircleLayer(
      'route-days', 'route-days-dot',
      const CircleLayerProperties(
        circleRadius: 11.0,
        circleColor: '#16302b',
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: 2.0,
      ),
      enableInteraction: false,
    );
    await controller.addSymbolLayer(
      'route-days', 'route-days-num',
      SymbolLayerProperties(
        textField: ['get', 'label'],
        textFont: ['OpenSans-Regular'],
        textSize: 12.0,
        textColor: '#ffffff',
        textAllowOverlap: true,
        textIgnorePlacement: true,
      ),
      enableInteraction: false,
    );
  }

  Future<void> _drawDayMarkers(RouteResult r) async {
    final poly = r.polyline;
    final totalMins = r.eta.inMinutes;
    final perDay = _hoursPerDay * 60;
    final days = totalMins <= 0 ? 1 : math.max(1, (totalMins / perDay).ceil());
    final feats = <Map<String, dynamic>>[];
    if (days > 1 && poly.length >= 2) {
      final cum = List<double>.filled(poly.length, 0);
      for (var i = 1; i < poly.length; i++) {
        cum[i] = cum[i - 1] +
            _haversineMetres(poly[i - 1].latitude, poly[i - 1].longitude,
                poly[i].latitude, poly[i].longitude);
      }
      final total = cum.last <= 0 ? 1.0 : cum.last;
      for (var k = 1; k < days; k++) {
        final target = (k * perDay / totalMins) * total;
        var idx = 0;
        while (idx < poly.length - 1 && cum[idx] < target) { idx++; }
        feats.add({
          'type': 'Feature',
          'geometry': {'type': 'Point',
            'coordinates': [poly[idx].longitude, poly[idx].latitude]},
          'properties': {'label': '${k + 1}'},
        });
      }
    }
    await _controller?.setGeoJsonSource(
        'route-days', {'type': 'FeatureCollection', 'features': feats});
  }

  /// The "Map layers" bottom sheet: show/hide facilities, notice severities and
  /// winding holes.
  void _openLayersSheet() {
    const stateLabels = {
      'closed': 'Closures', 'restricted': 'Restrictions', 'advisory': 'Advisories'
    };
    const stateColors = {
      'closed': Color(0xFFD32F2F), 'restricted': Color(0xFFF9A825), 'advisory': Color(0xFF1976D2)
    };
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text('Map layers', style: Theme.of(ctx).textTheme.titleMedium),
              ),
              for (final e in kPoiTypes.entries)
                CheckboxListTile(
                  dense: true,
                  value: !_hiddenTypes.contains(e.key),
                  secondary: _poiIcon(e.key, e.value.color, 20),
                  title: Text(e.value.label),
                  onChanged: (v) {
                    setSheet(() {
                      if (v == false) { _hiddenTypes.add(e.key); } else { _hiddenTypes.remove(e.key); }
                    });
                    _applyFeatureFilter();
                  },
                ),
              CheckboxListTile(
                dense: true,
                value: _showWinding,
                secondary: const Icon(Icons.refresh, color: Color(0xFF3949AB), size: 20),
                title: const Text('Winding hole'),
                onChanged: (v) {
                  setSheet(() => _showWinding = v ?? true);
                  _controller?.setLayerVisibility('winding-layer', _showWinding);
                },
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text('Notices', style: Theme.of(ctx).textTheme.labelLarge),
              ),
              for (final s in stateLabels.entries)
                CheckboxListTile(
                  dense: true,
                  value: !_hiddenStates.contains(s.key),
                  secondary: Icon(Icons.warning_amber_rounded, color: stateColors[s.key], size: 20),
                  title: Text(s.value),
                  onChanged: (v) {
                    setSheet(() {
                      if (v == false) { _hiddenStates.add(s.key); } else { _hiddenStates.remove(s.key); }
                    });
                    _refreshStoppages();
                  },
                ),
              CheckboxListTile(
                dense: true,
                value: _showPlanned,
                secondary: const Icon(Icons.schedule, color: Color(0xFF607D8B), size: 20),
                title: const Text('Planned / future'),
                onChanged: (v) {
                  setSheet(() => _showPlanned = v ?? false);
                  _refreshStoppages();
                },
              ),
            ],
          ),
        ),
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
    await _controller?.setGeoJsonSource('route-days', _emptyFc());
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
    setState(() => _routeEnd = p);
    await _computeRoute();
  }

  /// Compute + draw the route for the current start/end. Shared by tap-routing
  /// and "Route here" from a POI.
  Future<void> _computeRoute() async {
    final graph = _graph;
    if (graph == null || _routeStart == null || _routeEnd == null) return;
    setState(() => _routing = true);
    await _drawRouteEnds();

    final result = graph.route(_routeStart!, _routeEnd!);
    if (!mounted) return;
    setState(() {
      _route = result;
      _routeError = result == null
          ? 'No through route by water. These points are on separately-mapped '
              'waterways (e.g. an isolated canal or river) with no navigable '
              'link between them.'
          : null;
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
                      result.polyline.map((q) => [q.longitude, q.latitude]).toList(),
                },
              }
            ],
    });
    if (result != null) await _drawDayMarkers(result);
  }

  Future<void> _exportRoute() async {
    final r = _route;
    if (r == null) return;
    final h = r.eta.inHours, m = r.eta.inMinutes % 60;
    final stamp = DateTime.now().toIso8601String().split('T').first;
    await Exporter.saveOrShare(
      context,
      filename: 'canal-map-route-$stamp.gpx',
      // Date + any stoppages along the way baked into the file.
      content: r.toGpx(date: DateTime.now(), stoppages: _routeStoppages(r)),
      mimeType: 'application/gpx+xml',
      shareSubject: 'Canal Map route',
      shareText: 'Route: ${r.miles.toStringAsFixed(1)} miles, ${r.locks} locks, '
          '~${h > 0 ? '${h}h ' : ''}${m}m cruising.',
    );
  }

  /// Stoppages within ~250 m of the route polyline, for inclusion in the GPX
  /// export so a saved route also warns of closures. Uses the same visible set
  /// as the map (respects the planned/future toggle).
  List<RouteStoppage> _routeStoppages(RouteResult r) {
    final poly = r.polyline;
    if (poly.length < 2) return const [];
    final step = (poly.length / 600).ceil().clamp(1, poly.length);
    const thresholdM = 250.0;
    final out = <RouteStoppage>[];
    for (final s in _visibleStoppages) {
      var best = double.infinity;
      for (var i = 0; i < poly.length; i += step) {
        final d = _haversineMetres(
            s.lat, s.lon, poly[i].latitude, poly[i].longitude);
        if (d < best) best = d;
      }
      if (best <= thresholdM) {
        out.add(RouteStoppage(s.lat, s.lon, s.title, s.state));
      }
    }
    return out;
  }

  /// Ask for a name, then keep the current route on-device for reuse.
  Future<void> _saveCurrentRoute() async {
    final r = _route;
    if (r == null) return;
    final startName = _nearestPlaceLabel(r.polyline.first.latitude,
        r.polyline.first.longitude);
    final endName = _nearestPlaceLabel(
        r.polyline.last.latitude, r.polyline.last.longitude);
    final suggested = _routeSuggestedName(startName, endName);
    final controller = TextEditingController(text: suggested);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Save route'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;
    await SavedRoutes.add(
        SavedRoute.fromResult(name.isEmpty ? suggested : name, r));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Route saved')));
    }
  }

  String _routeSuggestedName(String startName, String endName) {
    String tidy(String s) =>
        s.replaceAll('near ', '').split(',').first.trim();
    final a = tidy(startName), b = tidy(endName);
    if (a.isNotEmpty && b.isNotEmpty) return '$a → $b';
    final stamp = DateTime.now().toIso8601String().split('T').first;
    return 'Route $stamp';
  }

  /// Browse all live stoppages/notices in a list; if the user picks one,
  /// fly the map to it and open its detail sheet.
  Future<void> _openStoppagesList() async {
    final picked = await Navigator.of(context).push<Stoppage>(MaterialPageRoute(
      builder: (_) => StoppagesListScreen(
        stoppages: _stoppages,
        freshness: _stoppagesFreshness,
      ),
    ));
    if (picked == null) return;
    await _controller?.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(picked.lat, picked.lon), 13));
    if (mounted) {
      _showStoppageSheet(
          Map<String, dynamic>.from(picked.toFeature()['properties'] as Map));
    }
  }

  /// Open the saved-routes list; if one is picked, draw it on the map.
  Future<void> _openSavedRoutes() async {
    final picked = await Navigator.of(context).push<SavedRoute>(
        MaterialPageRoute(builder: (_) => const SavedRoutesScreen()));
    if (picked == null) return;
    await _loadSavedRoute(picked);
  }

  Future<void> _loadSavedRoute(SavedRoute sr) => _displayRoute(sr.toResult());

  /// Browse popular cruising routes; if one is picked, draw it on the map.
  Future<void> _openPopularRoutes() async {
    final routes = await PopularRoute.load();
    if (!mounted) return;
    final picked = await Navigator.of(context).push<PopularRoute>(
        MaterialPageRoute(builder: (_) => PopularRoutesScreen(routes: routes)));
    if (picked == null) return;
    await _displayRoute(picked.toResult());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 3),
        content: Text('${picked.name} — tap the panel for the plan, '
            'or save it to your routes'),
      ));
    }
  }

  /// Draw a ready-made RouteResult on the map (saved route or popular route):
  /// enter route mode, show it, and frame it. No graph needed.
  Future<void> _displayRoute(RouteResult r) async {
    setState(() {
      _routeMode = true;
      _routeStart = r.polyline.first;
      _routeEnd = r.polyline.last;
      _route = r;
      _routeError = null;
    });
    await _controller?.setGeoJsonSource('route', _routeLineFc(r));
    await _drawRouteEnds();
    await _drawDayMarkers(r);
    final b = _routeBounds(r.polyline);
    await _controller?.animateCamera(CameraUpdate.newLatLngBounds(b,
        left: 40, right: 40, top: 80, bottom: 160));
  }

  LatLngBounds _routeBounds(List<LatLng> poly) {
    var minLa = 90.0, maxLa = -90.0, minLo = 180.0, maxLo = -180.0;
    for (final p in poly) {
      minLa = math.min(minLa, p.latitude);
      maxLa = math.max(maxLa, p.latitude);
      minLo = math.min(minLo, p.longitude);
      maxLo = math.max(maxLo, p.longitude);
    }
    return LatLngBounds(
        southwest: LatLng(minLa, minLo), northeast: LatLng(maxLa, maxLo));
  }

  /// A fuller journey plan: figures, the waterways you travel and the
  /// facilities you pass grouped by day, plus save / GPX / PDF.
  void _showRouteDetails() {
    final r = _route;
    if (r == null) return;
    final h = r.eta.inHours, m = r.eta.inMinutes % 60;
    final eta = h > 0 ? '${h}h ${m}m' : '${m}m';
    final totalMins = r.eta.inMinutes, totalMiles = r.miles;

    final itinerary = _routeItinerary(r.polyline);
    final waterways = <String>[];
    for (final it in itinerary.where((i) => i.entry.type == 'waterway')) {
      if (waterways.isEmpty || waterways.last != it.entry.name) {
        waterways.add(it.entry.name);
      }
    }
    final facilities =
        itinerary.where((i) => kPoiTypes.containsKey(i.entry.type)).toList();

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final perDay = _hoursPerDay * 60;
          final days = totalMins <= 0 ? 1 : math.max(1, (totalMins / perDay).ceil());
          int dayOf(double miles) {
            if (totalMiles <= 0 || totalMins <= 0) return 1;
            return ((miles / totalMiles) * totalMins / perDay).floor().clamp(0, days - 1) + 1;
          }

          // Along-the-way list with day headers.
          final along = <Widget>[];
          var cur = 0;
          for (final it in facilities) {
            final d = dayOf(it.miles);
            if (d != cur) {
              cur = d;
              along.add(Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 2),
                child: Text('Day $d',
                    style: Theme.of(ctx).textTheme.labelLarge
                        ?.copyWith(color: Theme.of(ctx).colorScheme.primary)),
              ));
            }
            final meta = kPoiTypes[it.entry.type]!;
            along.add(ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: _poiIcon(it.entry.type, meta.color, 22),
              title: Text(it.entry.name.isEmpty ? meta.label : it.entry.name),
              subtitle: Text(meta.label),
              trailing: Text('${it.miles.toStringAsFixed(1)} mi',
                  style: Theme.of(ctx).textTheme.bodySmall),
            ));
          }

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.62,
            maxChildSize: 0.92,
            builder: (ctx, scroll) => ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: [
                Text('Journey plan', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 16),
                _planRow(ctx, Icons.straighten, 'Distance',
                    '${r.miles.toStringAsFixed(1)} mi (${(r.metres / 1000).toStringAsFixed(1)} km)'),
                _planRow(ctx, Icons.lock, 'Locks', '${r.locks}'),
                _planRow(ctx, Icons.schedule, 'Estimated time',
                    '$eta  (≈3 mph + 10 min/lock)'),
                // Hours-per-day stepper → drives day splits + the map's day pills.
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Icon(Icons.event, size: 20, color: Theme.of(ctx).hintColor),
                    const SizedBox(width: 12),
                    Text('Per day:  ', style: Theme.of(ctx).textTheme.bodyMedium),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: _hoursPerDay <= 1 ? null : () {
                        setSheet(() => _hoursPerDay--);
                        _drawDayMarkers(r);
                      },
                    ),
                    Text('$_hoursPerDay h',
                        style: Theme.of(ctx).textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: _hoursPerDay >= 14 ? null : () {
                        setSheet(() => _hoursPerDay++);
                        _drawDayMarkers(r);
                      },
                    ),
                    const Spacer(),
                    Text('≈ $days day${days == 1 ? '' : 's'}',
                        style: Theme.of(ctx).textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ]),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: const Text('Save'),
                      onPressed: () { Navigator.pop(ctx); _saveCurrentRoute(); },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: const Text('GPX'),
                      onPressed: () { Navigator.pop(ctx); _exportRoute(); },
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: const Text('Download plan (PDF)'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _exportPdfPlan(r, facilities, waterways);
                    },
                  ),
                ),
                if (waterways.isNotEmpty) ...[
                  const Divider(height: 32),
                  Text('Waterways', style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(waterways.join('  →  '),
                      style: Theme.of(ctx).textTheme.bodyMedium),
                ],
                const Divider(height: 32),
                Text('Along the way (${facilities.length})',
                    style: Theme.of(ctx).textTheme.titleMedium),
                if (facilities.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('No mapped facilities within 300 m of this route.',
                        style: Theme.of(ctx).textTheme.bodySmall),
                  )
                else
                  ...along,
                const SizedBox(height: 8),
                Text('Estimate only — check conditions and notices before you set off.',
                    style: Theme.of(ctx).textTheme.bodySmall),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Build the branded PDF plan (with a schematic route map) and share it.
  Future<void> _exportPdfPlan(
      RouteResult r,
      List<({SearchEntry entry, double miles})> facilities,
      List<String> waterways) async {
    final totalMins = r.eta.inMinutes, totalMiles = r.miles;
    final perDay = _hoursPerDay * 60;
    final days = totalMins <= 0 ? 1 : math.max(1, (totalMins / perDay).ceil());
    int dayOf(double miles) {
      if (totalMiles <= 0 || totalMins <= 0) return 1;
      return ((miles / totalMiles) * totalMins / perDay).floor().clamp(0, days - 1) + 1;
    }

    final planFacs = [
      for (final it in facilities)
        PlanFacility(
          kPoiTypes[it.entry.type]!.label,
          it.entry.name.isEmpty ? kPoiTypes[it.entry.type]!.label : it.entry.name,
          it.miles,
          dayOf(it.miles),
        )
    ];
    Uint8List? img;
    try { img = await _renderRouteSchematic(r); } catch (_) {}
    await sharePlanPdf(
      miles: r.miles,
      locks: r.locks,
      etaMinutes: r.eta.inMinutes,
      hoursPerDay: _hoursPerDay,
      days: days,
      waterways: waterways,
      facilities: planFacs,
      routeImage: img,
    );
  }

  /// A clean schematic of the route (polyline + start/end + day pills) drawn to
  /// a PNG, for the PDF. Reliable + offline (no map snapshot needed).
  Future<Uint8List> _renderRouteSchematic(RouteResult r,
      {int w = 1000, int h = 620}) async {
    final poly = r.polyline;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..color = const Color(0xFFEEF3F6));
    if (poly.length >= 2) {
      var minLa = 90.0, maxLa = -90.0, minLo = 180.0, maxLo = -180.0;
      for (final p in poly) {
        minLa = math.min(minLa, p.latitude);
        maxLa = math.max(maxLa, p.latitude);
        minLo = math.min(minLo, p.longitude);
        maxLo = math.max(maxLo, p.longitude);
      }
      const pad = 60.0;
      final midLa = (minLa + maxLa) / 2;
      final cosLa = math.cos(midLa * math.pi / 180);
      final geoW = math.max(1e-6, (maxLo - minLo) * cosLa);
      final geoH = math.max(1e-6, maxLa - minLa);
      final scale = math.min((w - 2 * pad) / geoW, (h - 2 * pad) / geoH);
      final offX = (w - geoW * scale) / 2, offY = (h - geoH * scale) / 2;
      Offset project(LatLng p) => Offset(
          offX + (p.longitude - minLo) * cosLa * scale,
          offY + (maxLa - p.latitude) * scale);

      final path = Path();
      for (var i = 0; i < poly.length; i++) {
        final o = project(poly[i]);
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0xFF6A1B9A)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);

      void dot(LatLng p, Color col) {
        final o = project(p);
        canvas.drawCircle(o, 10, Paint()..color = Colors.white);
        canvas.drawCircle(o, 10,
            Paint()..color = col..style = PaintingStyle.stroke..strokeWidth = 4);
        canvas.drawCircle(o, 6, Paint()..color = col);
      }
      dot(poly.first, const Color(0xFF2E7D32));
      dot(poly.last, const Color(0xFFC62828));

      // Day pills.
      final totalMins = r.eta.inMinutes, perDay = _hoursPerDay * 60;
      final days = totalMins <= 0 ? 1 : math.max(1, (totalMins / perDay).ceil());
      if (days > 1) {
        final cum = List<double>.filled(poly.length, 0);
        for (var i = 1; i < poly.length; i++) {
          cum[i] = cum[i - 1] +
              _haversineMetres(poly[i - 1].latitude, poly[i - 1].longitude,
                  poly[i].latitude, poly[i].longitude);
        }
        final total = cum.last <= 0 ? 1.0 : cum.last;
        for (var k = 1; k < days; k++) {
          final target = (k * perDay / totalMins) * total;
          var idx = 0;
          while (idx < poly.length - 1 && cum[idx] < target) { idx++; }
          final o = project(poly[idx]);
          canvas.drawCircle(o, 14, Paint()..color = const Color(0xFF16302B));
          canvas.drawCircle(o, 14,
              Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2.5);
          final tp = TextPainter(
            textDirection: TextDirection.ltr,
            text: TextSpan(
                text: '${k + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          )..layout();
          tp.paint(canvas, Offset(o.dx - tp.width / 2, o.dy - tp.height / 2));
        }
      }
    }
    final img = await recorder.endRecording().toImage(w, h);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// Search-index entries (waterways + facilities) that lie within ~300 m of
  /// the route, ordered by how far along the route they are. Powers the
  /// detailed journey plan without needing the graph to carry names.
  List<({SearchEntry entry, double miles})> _routeItinerary(List<LatLng> poly) {
    if (poly.length < 2) return const [];
    final cum = List<double>.filled(poly.length, 0);
    for (var i = 1; i < poly.length; i++) {
      cum[i] = cum[i - 1] +
          _haversineMetres(poly[i - 1].latitude, poly[i - 1].longitude,
              poly[i].latitude, poly[i].longitude);
    }
    var minLa = 90.0, maxLa = -90.0, minLo = 180.0, maxLo = -180.0;
    for (final p in poly) {
      minLa = math.min(minLa, p.latitude);
      maxLa = math.max(maxLa, p.latitude);
      minLo = math.min(minLo, p.longitude);
      maxLo = math.max(maxLo, p.longitude);
    }
    final step = (poly.length / 600).ceil().clamp(1, poly.length);
    const margin = 0.01, thresholdM = 300.0;
    final out = <({SearchEntry entry, double miles})>[];
    for (final e in _searchEntries) {
      if (e.lat < minLa - margin || e.lat > maxLa + margin ||
          e.lon < minLo - margin || e.lon > maxLo + margin) {
        continue;
      }
      var best = double.infinity;
      var bestIdx = 0;
      for (var i = 0; i < poly.length; i += step) {
        final d = _haversineMetres(
            e.lat, e.lon, poly[i].latitude, poly[i].longitude);
        if (d < best) {
          best = d;
          bestIdx = i;
        }
      }
      if (best <= thresholdM) out.add((entry: e, miles: cum[bestIdx] / 1609.34));
    }
    out.sort((a, b) => a.miles.compareTo(b.miles));
    return out;
  }

  Widget _planRow(BuildContext ctx, IconData icon, String label, String value) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Theme.of(ctx).hintColor),
            const SizedBox(width: 12),
            Text('$label:  ', style: Theme.of(ctx).textTheme.bodyMedium),
            Expanded(
              child: Text(value,
                  style: Theme.of(ctx)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );

  /// "Route here": from the user's current GPS to a tapped feature.
  Future<void> _routeToPoint(LatLng dest) async {
    if (!await _ensureLocationPermission()) return;
    if (!mounted) return;
    setState(() => _locationEnabled = true);
    final here = await _controller?.requestMyLocationLatLng();
    if (!mounted) return;
    if (here == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Waiting for GPS — try again in a moment.')));
      return;
    }
    _graph ??= await RouteGraph.load('assets/routing.graph');
    if (!mounted) return;
    setState(() {
      _routeMode = true;
      _routeStart = here;
      _routeEnd = dest;
      _routeError = null;
    });
    await _computeRoute();
    await _controller?.animateCamera(CameraUpdate.newLatLngZoom(dest, 13));
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
      _showFeatureSheet({'type': picked.type, 'name': picked.name}, target);
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
    for (final s in _visibleStoppages) {
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

    // Winding holes (own runtime overlay — hit-tested in Dart like stoppages).
    if (_showWinding) {
      var wd = double.infinity;
      for (final p in _windingPts) {
        final d = _haversineMetres(
            latLng.latitude, latLng.longitude, p.latitude, p.longitude);
        if (d <= thresholdM && d < wd) wd = d;
      }
      if (wd < double.infinity) {
        if (mounted) _showWindingSheet();
        return;
      }
    }

    final features = await controller.queryRenderedFeaturesInRect(
      rect, [_featuresLayerId], null);
    if (features.isEmpty || !mounted) return;
    _showFeatureSheet(_propsOf(features.first), _coordOf(features.first, latLng));
  }

  Map<String, dynamic> _propsOf(dynamic feature) =>
      (feature is Map && feature['properties'] is Map)
          ? Map<String, dynamic>.from(feature['properties'] as Map)
          : <String, dynamic>{};

  LatLng _coordOf(dynamic feature, LatLng fallback) {
    try {
      final c = (feature['geometry'] as Map)['coordinates'] as List;
      return LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
    } catch (_) {
      return fallback;
    }
  }

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
        .map((e) => e.length >= 10 ? e.substring(0, 10) : e)
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

  void _showWindingSheet() {
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
              Row(children: [
                const Icon(Icons.refresh, color: Color(0xFF3949AB), size: 20),
                const SizedBox(width: 8),
                Text('WINDING HOLE',
                    style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF3949AB), fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 8),
              Text('Turning point', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text('A wider stretch where you can turn a full-length boat around.',
                  style: Theme.of(ctx).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }

  void _showFeatureSheet(Map<String, dynamic> props, LatLng location) {
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
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.directions_boat, size: 18),
                  label: const Text('Route here'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _routeToPoint(location);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Follow the app theme's brightness: if it flipped (user switched
    // light/dark), rebuild the map style so the map itself darkens too. Done
    // post-frame to avoid setState-during-build.
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark != _dark && _pmtilesPath != null) {
      _dark = dark;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() =>
              _styleJson = _buildStyle(_pmtilesPath!, _glyphsPath!, _dark));
        }
      });
    }

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
        // Colours come from the theme's appBarTheme (a dark shade of the chosen
        // seed), so the bar recolours when the user changes the colour theme.
        titleSpacing: 12,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.directions_boat_filled,
                  size: 20, color: Color(0xFFE0A92E)), // brand gold
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Canal Map',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600, height: 1.05)),
                Text('UK Waterways',
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.05,
                        color: Colors.white.withValues(alpha: 0.7),
                        letterSpacing: 0.3)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search places & waterways',
            onPressed: _searchEntries.isEmpty ? null : _openSearch,
          ),
          IconButton(
            icon: const Icon(Icons.layers_outlined),
            tooltip: 'Map layers',
            onPressed: _openLayersSheet,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: _openMenu,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'satellite',
                checked: _satellite,
                child: const Text('Satellite imagery (needs data)'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'notices',
                child: ListTile(
                  leading: Icon(Icons.warning_amber_rounded),
                  title: Text('Stoppages & notices'),
                  contentPadding: EdgeInsets.zero),
              ),
              const PopupMenuItem(
                value: 'log',
                child: ListTile(
                  leading: Icon(Icons.add_location_alt),
                  title: Text('Log my position'),
                  contentPadding: EdgeInsets.zero),
              ),
              const PopupMenuItem(
                value: 'logbook',
                child: ListTile(
                  leading: Icon(Icons.menu_book),
                  title: Text('Boat log'),
                  contentPadding: EdgeInsets.zero),
              ),
              const PopupMenuItem(
                value: 'saved',
                child: ListTile(
                  leading: Icon(Icons.route),
                  title: Text('Saved routes'),
                  contentPadding: EdgeInsets.zero),
              ),
              const PopupMenuItem(
                value: 'popular',
                child: ListTile(
                  leading: Icon(Icons.star_outline),
                  title: Text('Popular routes'),
                  contentPadding: EdgeInsets.zero),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  leading: Icon(Icons.palette_outlined),
                  title: Text('Appearance'),
                  contentPadding: EdgeInsets.zero),
              ),
              const PopupMenuItem(
                value: 'about',
                child: ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('About, help & legal'),
                  contentPadding: EdgeInsets.zero),
              ),
            ],
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
          SafeArea(child: _Legend(onTap: _openLayersSheet)),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_stoppagesFreshness != null)
                    _FreshnessChip(
                      label: _stoppagesFreshness!,
                      count: _stoppages.length,
                    ),
                  if (_bearing.abs() > 0.5)
                    _Compass(bearing: _bearing, onTap: _resetNorth),
                ],
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
                onTap: _route != null ? _showRouteDetails : null,
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
    this.onTap,
  });

  final bool routing;
  final RouteResult? route;
  final String? error;
  final bool hasStart;
  final VoidCallback? onTap;

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
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat(context, '${route!.miles.toStringAsFixed(1)} mi', 'distance'),
              _stat(context, '${route!.locks}', 'locks'),
              _stat(context, eta, 'approx time'),
            ],
          ),
          const SizedBox(height: 4),
          Text('Tap for the full plan & to save',
              style: Theme.of(context).textTheme.bodySmall),
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
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: body,
            ),
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

class _Compass extends StatelessWidget {
  const _Compass({required this.bearing, required this.onTap});
  final double bearing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Material(
        color: Colors.white,
        elevation: 3,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Transform.rotate(
              // Rotate the needle opposite the map so N always points north.
              angle: -bearing * math.pi / 180,
              child: const Icon(Icons.navigation, size: 22, color: Color(0xFFC0392B)),
            ),
          ),
        ),
      ),
    );
  }
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

/// A POI icon widget matching the map markers — the custom lock-gate chevron
/// for locks, a Material glyph otherwise.
Widget _poiIcon(String type, Color color, double size) => type == 'lock'
    ? _GateIcon(color: color, size: size)
    : Icon(kPoiTypes[type]?.icon ?? Icons.place, color: color, size: size);

/// The lock-gate chevron (the app-icon motif), drawn to any size.
class _GateIcon extends StatelessWidget {
  const _GateIcon({required this.color, this.size = 16});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(size, size), painter: _GatePainter(color));
}

class _GatePainter extends CustomPainter {
  const _GatePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.13
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = s.width * 0.34, hh = s.height * 0.15, cx = s.width / 2;
    for (final cy in [s.height * 0.40, s.height * 0.63]) {
      canvas.drawPath(
        Path()
          ..moveTo(cx - w, cy + hh)
          ..lineTo(cx, cy - hh)
          ..lineTo(cx + w, cy + hh),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_GatePainter old) => old.color != color;
}

class _Legend extends StatelessWidget {
  const _Legend({this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Card(
        elevation: 3,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('Facilities',
                      style: Theme.of(context).textTheme.labelMedium),
                  if (onTap != null) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.tune, size: 13, color: Theme.of(context).hintColor),
                  ],
                ]),
                const SizedBox(height: 6),
                for (final e in kPoiTypes.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _poiIcon(e.key, e.value.color, 15),
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
                      const Icon(Icons.refresh, size: 15, color: Color(0xFF3949AB)),
                      const SizedBox(width: 7),
                      Text('Winding hole',
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
      ),
    );
  }
}
