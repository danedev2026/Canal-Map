import 'package:flutter/material.dart';

import 'popular_routes.dart';

/// Browse well-known cruising routes. Tapping one returns it to the map, which
/// draws it and frames it.
class PopularRoutesScreen extends StatelessWidget {
  const PopularRoutesScreen({super.key, required this.routes});
  final List<PopularRoute> routes;

  String _eta(int mins) {
    final h = mins ~/ 60, m = mins % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Popular routes')),
      body: routes.isEmpty
          ? const Center(child: Text('No routes available.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    'Classic canal circuits and cruises. Tap one to see it on '
                    'the map — you can then save it or export it like any route.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                for (final r in routes)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: InkWell(
                      onTap: () => Navigator.pop(context, r),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.route, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(r.name,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                ),
                                const Icon(Icons.chevron_right,
                                    color: Colors.grey),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(r.description,
                                style: Theme.of(context).textTheme.bodySmall),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              children: [
                                _pill(context, Icons.straighten,
                                    '${r.miles.toStringAsFixed(0)} mi'),
                                _pill(context, Icons.lock, '${r.locks} locks'),
                                _pill(context, Icons.schedule,
                                    _eta(r.etaMinutes)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _pill(BuildContext context, IconData icon, String text) => Chip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(icon, size: 16),
        label: Text(text),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );
}
