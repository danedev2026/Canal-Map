import 'package:flutter/material.dart';

import 'saved_routes.dart';

/// Lists the user's saved routes. Tapping one returns it to the map (via
/// Navigator.pop) so the map can draw it; swipe or the bin icon deletes.
class SavedRoutesScreen extends StatefulWidget {
  const SavedRoutesScreen({super.key});

  @override
  State<SavedRoutesScreen> createState() => _SavedRoutesScreenState();
}

class _SavedRoutesScreenState extends State<SavedRoutesScreen> {
  List<SavedRoute> _routes = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final r = await SavedRoutes.load();
    if (mounted) setState(() => _routes = r);
  }

  Future<void> _delete(SavedRoute r) async {
    await SavedRoutes.delete(r);
    await _reload();
  }

  String _fmtDate(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }

  String _eta(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saved routes')),
      body: _routes.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No saved routes yet.\n\nPlan a route, open the journey plan, '
                  'and tap “Save route” to keep it here for next time.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              itemCount: _routes.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final r = _routes[i];
                return Dismissible(
                  key: ValueKey('${r.savedAt.toIso8601String()}_${r.name}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    color: const Color(0xFFC62828),
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (_) async {
                    await _delete(r);
                    return false;
                  },
                  child: ListTile(
                    leading: const Icon(Icons.route),
                    title: Text(r.name),
                    subtitle: Text(
                        '${r.miles.toStringAsFixed(1)} mi · ${r.locks} locks · '
                        '${_eta(r.eta)}  ·  saved ${_fmtDate(r.savedAt)}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete',
                      onPressed: () => _delete(r),
                    ),
                    onTap: () => Navigator.pop(context, r),
                  ),
                );
              },
            ),
    );
  }
}
