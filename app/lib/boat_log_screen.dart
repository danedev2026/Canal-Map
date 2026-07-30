import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'boat_log.dart';

/// View / add / export the boat movement log. `getLocation` returns the current
/// (lat, lon) or null; provided by the map screen (which owns location).
class BoatLogScreen extends StatefulWidget {
  const BoatLogScreen({super.key, required this.getLocation});
  final Future<(double, double)?> Function() getLocation;

  @override
  State<BoatLogScreen> createState() => _BoatLogScreenState();
}

class _BoatLogScreenState extends State<BoatLogScreen> {
  List<BoatLogEntry> _entries = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final e = await BoatLog.load();
    if (mounted) setState(() => _entries = e);
  }

  Future<void> _logNow() async {
    setState(() => _busy = true);
    final loc = await widget.getLocation();
    if (!mounted) return;
    setState(() => _busy = false);
    if (loc == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No GPS fix yet — try again in a moment.')));
      return;
    }
    await BoatLog.add(BoatLogEntry(DateTime.now(), loc.$1, loc.$2));
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Position logged')));
    }
  }

  Future<void> _export() async {
    if (_entries.isEmpty) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
                title: Text('Export boat log'),
                subtitle: Text('Choose a format')),
            ListTile(
              leading: const Icon(Icons.table_view),
              title: const Text('Spreadsheet (CSV)'),
              subtitle: const Text('Opens in any app — best for viewing / proof'),
              onTap: () => Navigator.pop(c, 'csv'),
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text('GPX'),
              subtitle: const Text('For importing into mapping / boating apps'),
              onTap: () => Navigator.pop(c, 'gpx'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;

    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().split('T').first;
    final File file;
    final String mime;
    if (choice == 'csv') {
      file = File('${dir.path}/canal-map-boat-log-$stamp.csv');
      await file.writeAsString(BoatLog.toCsv(_entries), flush: true);
      mime = 'text/csv';
    } else {
      file = File('${dir.path}/canal-map-boat-log-$stamp.gpx');
      await file.writeAsString(BoatLog.toGpx(_entries), flush: true);
      mime = 'application/gpx+xml';
    }
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: mime)],
      subject: 'Boat movement log',
      text: 'Boat movement log from Canal Map (${_entries.length} positions).',
    ));
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear the whole log?'),
        content: const Text('This deletes every logged position. Export first '
            'if you need to keep it. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    for (final e in [..._entries]) {
      await BoatLog.delete(e);
    }
    await _reload();
  }

  String _fmt(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}  ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Boat log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export as GPX',
            onPressed: _entries.isEmpty ? null : _export,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
            onPressed: _entries.isEmpty ? null : _clearAll,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _logNow,
        icon: _busy
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add_location_alt),
        label: const Text('Log position'),
      ),
      body: _entries.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No positions logged yet.\n\nTap “Log position” each time you '
                  'moor up to build a movement record you can export as proof.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final e = _entries[i];
                return ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(_fmt(e.time)),
                  subtitle: Text(
                      '${e.lat.toStringAsFixed(5)}, ${e.lon.toStringAsFixed(5)}'),
                );
              },
            ),
    );
  }
}
