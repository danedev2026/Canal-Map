import 'package:flutter/material.dart';

import 'boat_log.dart';
import 'exporter.dart';

/// View / add / edit / export the boat movement log. [getLocation] returns the
/// current (lat, lon) or null; [nearestPlace] turns a position into a short
/// human label ("near Braunston"). Both are supplied by the map screen, which
/// owns location and the search index.
class BoatLogScreen extends StatefulWidget {
  const BoatLogScreen({
    super.key,
    required this.getLocation,
    required this.nearestPlace,
  });
  final Future<(double, double)?> Function() getLocation;
  final String Function(double lat, double lon) nearestPlace;

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
    final place = widget.nearestPlace(loc.$1, loc.$2);
    await BoatLog.add(BoatLogEntry(DateTime.now(), loc.$1, loc.$2, place: place));
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(place.isEmpty ? 'Position logged' : 'Logged $place')));
    }
  }

  Future<void> _editNote(BoatLogEntry e) async {
    final controller = TextEditingController(text: e.note);
    final note = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'e.g. moored above the top lock',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (note == null) return;
    await BoatLog.update(e.copyWith(note: note));
    await _reload();
  }

  Future<void> _deleteOne(BoatLogEntry e) async {
    await BoatLog.delete(e);
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Entry deleted')));
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
    if (choice == null || !mounted) return;

    final stamp = DateTime.now().toIso8601String().split('T').first;
    if (choice == 'csv') {
      await Exporter.saveOrShare(
        context,
        filename: 'canal-map-boat-log-$stamp.csv',
        content: BoatLog.toCsv(_entries),
        mimeType: 'text/csv',
        shareSubject: 'Boat movement log',
        shareText: 'Boat movement log from Canal Map (${_entries.length} positions).',
      );
    } else {
      await Exporter.saveOrShare(
        context,
        filename: 'canal-map-boat-log-$stamp.gpx',
        content: BoatLog.toGpx(_entries),
        mimeType: 'application/gpx+xml',
        shareSubject: 'Boat movement log',
        shareText: 'Boat movement log from Canal Map (${_entries.length} positions).',
      );
    }
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
            tooltip: 'Export',
            onPressed: _entries.isEmpty ? null : _export,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear whole log',
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
                final coords =
                    '${e.lat.toStringAsFixed(5)}, ${e.lon.toStringAsFixed(5)}';
                final subtitleLines = <String>[
                  if (e.place.isNotEmpty) e.place,
                  coords,
                  if (e.note.isNotEmpty) '“${e.note}”',
                ];
                return Dismissible(
                  key: ValueKey('${e.time.toIso8601String()}_${e.lat}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    color: const Color(0xFFC62828),
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (_) async {
                    await _deleteOne(e);
                    return false; // _reload rebuilds the list from disk
                  },
                  child: ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(_fmt(e.time)),
                    subtitle: Text(subtitleLines.join('\n')),
                    isThreeLine: subtitleLines.length > 2,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_note),
                          tooltip: 'Add / edit note',
                          onPressed: () => _editNote(e),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete this entry',
                          onPressed: () => _deleteOne(e),
                        ),
                      ],
                    ),
                    onTap: () => _editNote(e),
                  ),
                );
              },
            ),
    );
  }
}
