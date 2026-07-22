import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

/// Journey-time heuristic (tunable). ~3 mph cruising + fixed minutes per lock.
const double _mphMetresPerMin = 3 * 1609.34 / 60; // metres travelled per minute
const int _minsPerLock = 10;

class RouteResult {
  RouteResult(this.polyline, this.metres, this.locks, this.eta);
  final List<LatLng> polyline;
  final double metres;
  final int locks;
  final Duration eta;

  double get miles => metres / 1609.34;
}

/// On-device routable graph, loaded from the bundled binary (see
/// routing_graph.py). CSR adjacency; A* over ~166k nodes runs in well under a
/// second. Routes only succeed within a connected component.
class RouteGraph {
  RouteGraph._(this._lon, this._lat, this._isLock, this._offsets, this._nbr);

  final Float32List _lon;
  final Float32List _lat;
  final Uint8List _isLock;
  final Int32List _offsets; // length n+1 (CSR row pointers)
  final Int32List _nbr; // length 2*edges (neighbour node ids)

  int get nodeCount => _lon.length;

  static Future<RouteGraph> load(String asset) async {
    final bytes = await rootBundle.load(asset);
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
    var off = 0;

    // magic "CMRG" + version
    if (bd.getUint8(0) != 0x43 || bd.getUint8(1) != 0x4D ||
        bd.getUint8(2) != 0x52 || bd.getUint8(3) != 0x47) {
      throw StateError('bad routing graph magic');
    }
    off = 5; // 4 magic + 1 version

    final n = bd.getUint32(off, Endian.little);
    off += 4;
    final lon = Float32List(n);
    final lat = Float32List(n);
    for (var i = 0; i < n; i++) {
      lon[i] = bd.getFloat32(off, Endian.little);
      lat[i] = bd.getFloat32(off + 4, Endian.little);
      off += 8;
    }

    final isLock = Uint8List(n);
    final lockCount = bd.getUint32(off, Endian.little);
    off += 4;
    for (var i = 0; i < lockCount; i++) {
      isLock[bd.getUint32(off, Endian.little)] = 1;
      off += 4;
    }

    final edgeCount = bd.getUint32(off, Endian.little);
    off += 4;
    final ea = Int32List(edgeCount);
    final eb = Int32List(edgeCount);
    final deg = Int32List(n);
    for (var i = 0; i < edgeCount; i++) {
      final a = bd.getUint32(off, Endian.little);
      final b = bd.getUint32(off + 4, Endian.little);
      off += 8;
      ea[i] = a;
      eb[i] = b;
      deg[a]++;
      deg[b]++;
    }

    // CSR build
    final offsets = Int32List(n + 1);
    for (var i = 0; i < n; i++) {
      offsets[i + 1] = offsets[i] + deg[i];
    }
    final nbr = Int32List(edgeCount * 2);
    final cursor = Int32List.fromList(offsets.sublist(0, n));
    for (var i = 0; i < edgeCount; i++) {
      final a = ea[i], b = eb[i];
      nbr[cursor[a]++] = b;
      nbr[cursor[b]++] = a;
    }
    return RouteGraph._(lon, lat, isLock, offsets, nbr);
  }

  double _metres(int a, int b) => _haversine(_lat[a], _lon[a], _lat[b], _lon[b]);

  int nearestNode(LatLng p) {
    var best = -1;
    var bestD = double.infinity;
    // Squared-degree pre-filter keeps this ~5ms over 166k nodes.
    final plon = p.longitude, plat = p.latitude;
    for (var i = 0; i < _lon.length; i++) {
      final dlon = _lon[i] - plon;
      final dlat = _lat[i] - plat;
      final d = dlon * dlon + dlat * dlat;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  /// A* shortest path by distance. Returns null if unreachable (different
  /// connected component).
  RouteResult? route(LatLng from, LatLng to) {
    final start = nearestNode(from);
    final goal = nearestNode(to);
    if (start < 0 || goal < 0) return null;
    if (start == goal) return RouteResult([_ll(start)], 0, 0, Duration.zero);

    final n = _lon.length;
    final gScore = Float64List(n)..fillRange(0, n, double.infinity);
    final cameFrom = Int32List(n)..fillRange(0, n, -1);
    gScore[start] = 0;

    final open = _MinHeap();
    open.push(_h(start, goal), start);

    while (!open.isEmpty) {
      final u = open.pop();
      if (u == goal) break;
      final g = gScore[u];
      for (var e = _offsets[u]; e < _offsets[u + 1]; e++) {
        final v = _nbr[e];
        final ng = g + _metres(u, v);
        if (ng < gScore[v]) {
          gScore[v] = ng;
          cameFrom[v] = u;
          open.push(ng + _h(v, goal), v);
        }
      }
    }

    if (cameFrom[goal] < 0) return null;

    // Reconstruct.
    final path = <int>[];
    for (var cur = goal; cur != -1; cur = cameFrom[cur]) {
      path.add(cur);
      if (cur == start) break;
    }
    final rev = path.reversed.toList();
    final poly = <LatLng>[];
    var locks = 0;
    for (var i = 0; i < rev.length; i++) {
      poly.add(_ll(rev[i]));
      if (_isLock[rev[i]] == 1 && i != 0 && i != rev.length - 1) locks++;
    }
    final metres = gScore[goal];
    final mins = metres / _mphMetresPerMin + locks * _minsPerLock;
    return RouteResult(poly, metres, locks, Duration(minutes: mins.round()));
  }

  LatLng _ll(int i) => LatLng(_lat[i], _lon[i]);

  double _h(int node, int goal) =>
      _haversine(_lat[node], _lon[node], _lat[goal], _lon[goal]);
}

const double _rEarth = 6371000.0;

double _haversine(double lat1, double lon1, double lat2, double lon2) {
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = (lat2 - lat1) * math.pi / 180;
  final dl = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return _rEarth * 2 * math.asin(math.min(1, math.sqrt(a)));
}

/// Minimal binary min-heap keyed by double priority (parallel arrays; avoids a
/// package dependency).
class _MinHeap {
  final List<double> _pri = [];
  final List<int> _val = [];

  bool get isEmpty => _val.isEmpty;

  void push(double pri, int val) {
    _pri.add(pri);
    _val.add(val);
    var i = _val.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_pri[parent] <= _pri[i]) break;
      _swap(i, parent);
      i = parent;
    }
  }

  int pop() {
    final top = _val[0];
    final lastPri = _pri.removeLast();
    final lastVal = _val.removeLast();
    if (_val.isNotEmpty) {
      _pri[0] = lastPri;
      _val[0] = lastVal;
      var i = 0;
      final n = _val.length;
      while (true) {
        final l = 2 * i + 1, r = 2 * i + 2;
        var s = i;
        if (l < n && _pri[l] < _pri[s]) s = l;
        if (r < n && _pri[r] < _pri[s]) s = r;
        if (s == i) break;
        _swap(i, s);
        i = s;
      }
    }
    return top;
  }

  void _swap(int a, int b) {
    final tp = _pri[a];
    _pri[a] = _pri[b];
    _pri[b] = tp;
    final tv = _val[a];
    _val[a] = _val[b];
    _val[b] = tv;
  }
}
