import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'stoppages.dart';

const Map<String, ({Color color, String label})> _states = {
  'closed': (color: Color(0xFFD32F2F), label: 'Closure'),
  'restricted': (color: Color(0xFFF9A825), label: 'Restriction'),
  'advisory': (color: Color(0xFF1976D2), label: 'Advisory'),
};

({Color color, String label}) _stateMeta(String s) =>
    _states[s] ?? (color: const Color(0xFFD32F2F), label: 'Notice');

/// A browsable list of every live stoppage / notice, with search + state
/// filters. "Show on map" returns the chosen stoppage to the map screen.
class StoppagesListScreen extends StatefulWidget {
  const StoppagesListScreen({
    super.key,
    required this.stoppages,
    this.freshness,
  });
  final List<Stoppage> stoppages;
  final String? freshness;

  @override
  State<StoppagesListScreen> createState() => _StoppagesListScreenState();
}

class _StoppagesListScreenState extends State<StoppagesListScreen> {
  String _query = '';
  String _filter = 'all'; // all | closed | restricted | advisory

  bool _isFuture(Stoppage s) {
    final start = DateTime.tryParse(s.start);
    return start != null && start.isAfter(DateTime.now());
  }

  List<Stoppage> get _filtered {
    final q = _query.trim().toLowerCase();
    final list = widget.stoppages.where((s) {
      if (_filter != 'all' && s.state != _filter) return false;
      if (q.isEmpty) return true;
      return s.title.toLowerCase().contains(q) ||
          s.waterway.toLowerCase().contains(q) ||
          s.reason.toLowerCase().contains(q);
    }).toList();
    // Current first, then by severity (closed→restricted→advisory), then name.
    int sev(String st) => st == 'closed' ? 0 : (st == 'restricted' ? 1 : 2);
    list.sort((a, b) {
      final fa = _isFuture(a) ? 1 : 0, fb = _isFuture(b) ? 1 : 0;
      if (fa != fb) return fa - fb;
      final sa = sev(a.state), sb = sev(b.state);
      if (sa != sb) return sa - sb;
      return a.waterway.compareTo(b.waterway);
    });
    return list;
  }

  int _count(String state) =>
      widget.stoppages.where((s) => s.state == state).length;

  static const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                       'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  String _fmtDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso.length >= 10 ? iso.substring(0, 10) : iso;
    return '${d.day} ${_mon[d.month - 1]} ${d.year}';
  }

  String _prettyDates(Stoppage s) =>
      [s.start, s.end].where((e) => e.isNotEmpty).map(_fmtDate).join(' → ');

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stoppages & notices'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(104),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: 'Search waterway, title or reason',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    _chip('all', 'All (${widget.stoppages.length})'),
                    _chip('closed', 'Closures (${_count('closed')})'),
                    _chip('restricted', 'Restrictions (${_count('restricted')})'),
                    _chip('advisory', 'Advisories (${_count('advisory')})'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('No matching notices.', textAlign: TextAlign.center),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: items.length + 1,
              itemBuilder: (ctx, i) {
                if (i == 0) {
                  return widget.freshness == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 8, left: 4),
                          child: Text(widget.freshness!,
                              style: Theme.of(ctx).textTheme.bodySmall),
                        );
                }
                return _card(items[i - 1]);
              },
            ),
    );
  }

  Widget _chip(String value, String label) {
    final selected = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _filter = value),
      ),
    );
  }

  Widget _card(Stoppage s) {
    final meta = _stateMeta(s.state);
    final future = _isFuture(s);
    final dates = _prettyDates(s);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => _openDetail(s),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 6, color: meta.color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: meta.color, size: 18),
                          const SizedBox(width: 6),
                          Text(meta.label.toUpperCase(),
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                      color: meta.color,
                                      fontWeight: FontWeight.bold)),
                          if (future) ...[
                            const SizedBox(width: 8),
                            _pill('PLANNED'),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(s.title,
                          style: Theme.of(context).textTheme.titleSmall),
                      if (s.waterway.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(s.waterway,
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                      if (dates.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(dates,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Theme.of(context).hintColor)),
                      ],
                    ],
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(Icons.chevron_right, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(letterSpacing: 0.3)),
      );

  void _openDetail(Stoppage s) {
    final meta = _stateMeta(s.state);
    final dates = _prettyDates(s);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: meta.color, size: 20),
                const SizedBox(width: 8),
                Text(meta.label.toUpperCase(),
                    style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                        color: meta.color, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            Text(s.title, style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (s.waterway.isNotEmpty) _kv(ctx, 'Waterway', s.waterway),
            if (s.reason.isNotEmpty) _kv(ctx, 'Reason', s.reason),
            if (dates.isNotEmpty) _kv(ctx, 'Dates', dates),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.map, size: 18),
              label: const Text('Show on map'),
              onPressed: () {
                Navigator.pop(ctx); // sheet
                Navigator.pop(context, s); // screen → map flies to it
              },
            ),
            if (s.url.isNotEmpty) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('More info'),
                onPressed: () => launchUrl(Uri.parse(s.url),
                    mode: LaunchMode.externalApplication),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext ctx, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: RichText(
          text: TextSpan(
            style: Theme.of(ctx).textTheme.bodyMedium,
            children: [
              TextSpan(
                  text: '$k: ',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: v),
            ],
          ),
        ),
      );
}
