import 'package:flutter/material.dart';

import 'app_settings.dart';

/// Appearance settings: light/dark/system and the colour theme. Changes apply
/// instantly and are remembered.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: AnimatedBuilder(
        animation: s,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Theme', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto)),
                ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode)),
                ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode)),
              ],
              selected: {s.mode},
              onSelectionChanged: (sel) => s.setMode(sel.first),
            ),
            const SizedBox(height: 8),
            Text('“System” follows your phone’s light/dark setting.',
                style: Theme.of(context).textTheme.bodySmall),
            const Divider(height: 40),
            Text('Colour', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (var i = 0; i < kSeedThemes.length; i++)
                  _SeedSwatch(
                    theme: kSeedThemes[i],
                    selected: i == s.seedIndex,
                    onTap: () => s.setSeedIndex(i),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch(
      {required this.theme, required this.selected, required this.onTap});
  final SeedTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: theme.seed,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.black26,
                width: selected ? 4 : 1,
              ),
            ),
            child: selected
                ? const Icon(Icons.check, color: Colors.white)
                : null,
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 72,
            child: Text(theme.name,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
