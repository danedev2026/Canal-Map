import 'package:flutter/material.dart';

/// Data attribution — required by the licences of our sources. Reachable from
/// the info button in the app bar and the map's "i" control.
class AttributionScreen extends StatelessWidget {
  const AttributionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About & data sources')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Canal Map', style: t.headlineSmall),
          const SizedBox(height: 4),
          Text('A free, offline map of the UK’s connected navigable network — '
              'canals and navigable rivers — for narrowboaters.',
              style: t.bodyMedium),
          const Divider(height: 32),
          _Source(
            title: 'OpenStreetMap',
            body: 'Map network geometry (canals and navigable rivers) and many '
                'facilities. © OpenStreetMap contributors, available under the '
                'Open Database License (ODbL).',
          ),
          _Source(
            title: 'Canal & River Trust Open Data',
            body: 'Authoritative facilities (water points, Elsan, pump-out, '
                'refuse) and the live navigation notices / stoppages feed.',
          ),
          _Source(
            title: 'Environment Agency Open Data (OGL)',
            body: 'River navigation facilities on EA-managed waters, where used.',
          ),
          const Divider(height: 32),
          Text('Privacy', style: t.titleMedium),
          const SizedBox(height: 4),
          Text('The map works fully offline. The only data fetched at runtime '
              'is the daily stoppages file; no accounts, no tracking, no ads.',
              style: t.bodyMedium),
          const SizedBox(height: 24),
          Text('Routing distances and times are estimates (≈3 mph plus time '
              'per lock) — always check conditions and notices before setting off.',
              style: t.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
        ],
      ),
    );
  }
}

class _Source extends StatelessWidget {
  const _Source({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.titleMedium),
          const SizedBox(height: 2),
          Text(body, style: t.bodyMedium),
        ],
      ),
    );
  }
}
