import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A single logged boat position — the evidence a continuous cruiser keeps to
/// show the boat has moved. Stored locally only; never sent anywhere.
/// [place] is an auto-filled nearest-landmark label (e.g. "near Braunston");
/// [note] is the boater's own free text (e.g. "moored above top lock").
class BoatLogEntry {
  BoatLogEntry(this.time, this.lat, this.lon, {this.place = '', this.note = ''});
  final DateTime time;
  final double lat;
  final double lon;
  final String place;
  final String note;

  BoatLogEntry copyWith({String? place, String? note}) => BoatLogEntry(
        time, lat, lon,
        place: place ?? this.place,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => {
        't': time.toIso8601String(),
        'lat': lat,
        'lon': lon,
        'place': place,
        'note': note,
      };

  factory BoatLogEntry.fromJson(Map<String, dynamic> j) => BoatLogEntry(
        DateTime.parse(j['t'] as String),
        (j['lat'] as num).toDouble(),
        (j['lon'] as num).toDouble(),
        place: (j['place'] ?? '') as String,
        note: (j['note'] ?? '') as String,
      );
}

/// Local, on-device boat log. No server, no sync — the user exports a file when
/// they want proof of movement.
class BoatLog {
  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/boat_log.json');
  }

  static Future<List<BoatLogEntry>> load() async {
    final f = await _file();
    if (!await f.exists()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      final out = list
          .map((e) => BoatLogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      out.sort((a, b) => b.time.compareTo(a.time)); // newest first
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<List<BoatLogEntry>> add(BoatLogEntry entry) async {
    final entries = await load();
    entries.add(entry);
    await _write(entries);
    return entries..sort((a, b) => b.time.compareTo(a.time));
  }

  static Future<void> delete(BoatLogEntry entry) async {
    final entries = await load()
      ..removeWhere((e) => e.time == entry.time && e.lat == entry.lat);
    await _write(entries);
  }

  /// Replace the entry with the same timestamp (used when the boater edits its
  /// note). Matches on time + position so it's stable across reloads.
  static Future<void> update(BoatLogEntry entry) async {
    final entries = await load();
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].time == entry.time && entries[i].lat == entry.lat) {
        entries[i] = entry;
        break;
      }
    }
    await _write(entries);
  }

  static Future<void> _write(List<BoatLogEntry> entries) async {
    final f = await _file();
    await f.writeAsString(
        jsonEncode(entries.map((e) => e.toJson()).toList()), flush: true);
  }

  /// GPX of dated waypoints — opens in any mapping/boating app and reads as a
  /// clear timestamped movement record.
  static String toGpx(List<BoatLogEntry> entries) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="Canal Map: UK Waterways" '
          'xmlns="http://www.topografix.com/GPX/1/1">');
    final chrono = [...entries]..sort((a, b) => a.time.compareTo(b.time));
    for (final e in chrono) {
      final t = e.time.toUtc().toIso8601String();
      final desc = [e.place, e.note].where((s) => s.isNotEmpty).join(' — ');
      b
        ..writeln('  <wpt lat="${e.lat.toStringAsFixed(6)}" '
            'lon="${e.lon.toStringAsFixed(6)}">')
        ..writeln('    <time>$t</time>')
        ..writeln('    <name>${_esc(_stamp(e.time))}</name>');
      if (desc.isNotEmpty) b.writeln('    <desc>${_esc(desc)}</desc>');
      b.writeln('  </wpt>');
    }
    b.writeln('</gpx>');
    return b.toString();
  }

  /// CSV — opens in any spreadsheet, email preview or text viewer (unlike GPX,
  /// which needs a mapping app). Best for viewing the movement record as proof.
  static String toCsv(List<BoatLogEntry> entries) {
    final b = StringBuffer('Date,Time,Latitude,Longitude,Location,Note\n');
    final chrono = [...entries]..sort((a, b) => a.time.compareTo(b.time));
    for (final e in chrono) {
      final s = _stamp(e.time).split(' ');
      b.writeln('${s[0]},${s.length > 1 ? s[1] : ''},'
          '${e.lat.toStringAsFixed(6)},${e.lon.toStringAsFixed(6)},'
          '${_csv(e.place)},${_csv(e.note)}');
    }
    return b.toString();
  }

  /// Quote a CSV field if it contains a comma, quote or newline.
  static String _csv(String s) {
    if (s.isEmpty) return '';
    if (s.contains(RegExp('[",\n]'))) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
