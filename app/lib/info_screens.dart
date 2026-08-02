import 'package:flutter/material.dart';

/// A simple scrollable content screen: a title and a list of headed sections.
class _ContentScreen extends StatelessWidget {
  const _ContentScreen({required this.title, required this.sections, this.intro});
  final String title;
  final String? intro;
  final List<(String, String)> sections;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (intro != null) ...[
            Text(intro!, style: t.bodyLarge),
            const SizedBox(height: 8),
          ],
          for (final s in sections) ...[
            const SizedBox(height: 16),
            Text(s.$1, style: t.titleMedium),
            const SizedBox(height: 4),
            Text(s.$2, style: t.bodyMedium),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Educational content: staying safe and cruising considerately. General
/// guidance — not a substitute for training, a licence, or local knowledge.
class SafetyScreen extends StatelessWidget {
  const SafetyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const _ContentScreen(
      title: 'Safety & canal use',
      intro: 'A quick guide for staying safe and cruising considerately on the '
          'UK’s canals and navigable rivers. General guidance only — always '
          'follow signs, notices and any instructions from lock keepers or the '
          'navigation authority.',
      sections: [
        (
          'Wear a life jacket',
          'Falls into cold water are the biggest risk on the cut. Wear a '
              'buoyancy aid on deck, at locks and when working ropes — '
              'especially in winter, when cold-water shock can be fatal within '
              'minutes. Keep children in life jackets at all times.'
        ),
        (
          'Working locks safely',
          'Never stand on lock gates or beams while they’re moving. Keep '
              'fingers and ropes clear of gates and paddle gear. Open paddles '
              'slowly so the boat isn’t thrown about, and keep the boat off the '
              'cill (the ledge at the top gate) when descending — grounding on '
              'it can sink a boat. Close paddles and gates behind you.'
        ),
        (
          'Speed and wash',
          'The limit is usually 4 mph, but the rule is “no breaking wash”. Slow '
              'right down past moored boats, anglers, and other craft — your '
              'wash pulls their pins and rocks their homes. Slow doesn’t mean '
              'drifting: keep enough way on to steer.'
        ),
        (
          'Bridges, tunnels and blind bends',
          'Most bridges are single-file — the boat already committed has right '
              'of way. Sound your horn approaching blind bridge-holes and bends. '
              'In tunnels, put your headlight on, keep to the right where you can '
              'pass, and never enter if a boat is already coming the other way '
              'in a single-file tunnel.'
        ),
        (
          'Tidal waters',
          'Sections marked as tidal (dashed orange on the map) need extra '
              'planning: check tide times, carry an anchor, tell someone your '
              'plan, and don’t attempt them without suitable experience. Many '
              'insurers and licences have conditions for tidal cruising.'
        ),
        (
          'Mooring',
          'Moor only where it’s allowed — not on lock landings, water points, '
              'winding holes or in bridge-holes. Use both fore and aft lines, '
              'hammer pins in at an angle away from the boat, and leave a light '
              'or hi-vis on your pins so others see them. Respect visitor-mooring '
              'time limits.'
        ),
        (
          'Weil’s disease & water hygiene',
          'Canal water can carry Weil’s disease (leptospirosis). Cover cuts, '
              'wash or sanitise hands before eating, and don’t swim in canals. '
              'See a doctor if you get flu-like symptoms after contact with the '
              'water and mention you’ve been on the canals.'
        ),
        (
          'Check before you travel',
          'Stoppages and notices (shown live on the map) can close a lock or '
              'pound at short notice. Check them when planning and again before '
              'you set off — a single closure can block a whole route.'
        ),
      ],
    );
  }
}

/// Short, plain-English terms. The app is free, offline and takes no accounts
/// or payment, so these are deliberately light — mainly a use-at-your-own-risk
/// notice appropriate to a navigation aid.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const _ContentScreen(
      title: 'Terms of use',
      intro: 'Canal Map: UK Waterways is a free app provided as-is to help you '
          'explore the network. By using it you agree to the following.',
      sections: [
        (
          'A guide, not a guarantee',
          'Map data, facilities, routes, distances, lock counts and journey '
              'times are estimates compiled from open data and may be '
              'incomplete, out of date or wrong. They are not a substitute for '
              'official charts, signage, notices, or your own judgement as the '
              'person in control of the boat.'
        ),
        (
          'Navigate responsibly',
          'You are responsible for the safe navigation of your vessel and for '
              'complying with the navigation authority’s rules, licensing and '
              'any local restrictions. Always check current stoppages and '
              'conditions before and during a journey.'
        ),
        (
          'No warranty, no liability',
          'The app is provided without warranty of any kind. To the extent '
              'permitted by law, the developer accepts no liability for any '
              'loss, damage or injury arising from use of, or reliance on, the '
              'app or its data.'
        ),
        (
          'Your data stays yours',
          'The app has no accounts and no tracking. Anything you create — your '
              'boat log and saved routes — is stored only on your device. See '
              'the privacy policy for details.'
        ),
        (
          'Data & attribution',
          'Contains information from OpenStreetMap (ODbL), the Canal & River '
              'Trust and the Environment Agency under their respective open '
              'licences. Optional aerial imagery © Esri and its suppliers.'
        ),
      ],
    );
  }
}
