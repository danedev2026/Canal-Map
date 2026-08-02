import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'info_screens.dart';
import 'settings_screen.dart';

/// The user's existing privacy policy (hosted separately by them).
const String kPrivacyUrl =
    'https://danedev2026.github.io/canal-map/privacy.html';

/// Play Store listing, for the "Rate this app" action.
const String kPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=uk.canalmap.canal_map';

Future<void> _open(BuildContext context, String url) async {
  final ok = await launchUrl(Uri.parse(url),
      mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Could not open $url')));
  }
}

/// About / help / legal hub. Reachable from the app-bar menu. Also links out to
/// the (externally hosted) privacy policy and the Play Store rating page.
class AttributionScreen extends StatelessWidget {
  const AttributionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About, help & legal')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Canal Map', style: t.headlineSmall),
          const SizedBox(height: 4),
          Text('A free, offline map of the UK’s connected navigable network — '
              'canals and navigable rivers — for narrowboaters.',
              style: t.bodyMedium),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Appearance'),
                  subtitle: const Text('Light / dark mode and colour theme'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const SettingsScreen())),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.health_and_safety_outlined),
                  title: const Text('Safety & canal use'),
                  subtitle: const Text('Staying safe and cruising considerately'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const SafetyScreen())),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.star_outline),
                  title: const Text('Rate this app'),
                  subtitle: const Text('Leave a review on Google Play'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => _open(context, kPlayStoreUrl),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy policy'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => _open(context, kPrivacyUrl),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Terms of use'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const TermsScreen())),
                ),
              ],
            ),
          ),
          const Divider(height: 32),
          Text('Data sources', style: t.titleMedium),
          const SizedBox(height: 8),
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
          _Source(
            title: 'Esri World Imagery',
            body: 'Optional satellite basemap (only when you turn it on and are '
                'online). Imagery © Esri, Maxar, Earthstar Geographics.',
          ),
          const SizedBox(height: 20),
          Text('The map works fully offline. The only data fetched at runtime '
              'is the daily stoppages file; no accounts, no tracking, no ads. '
              'Your boat log and saved routes stay on your device.',
              style: t.bodyMedium),
          const SizedBox(height: 20),
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
