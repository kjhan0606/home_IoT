import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/hub_state.dart';
import '../summary/home_summary.dart';
import 'device_detail_screen.dart';
import 'home_summary_screen.dart';

IconData summaryIcon(SummaryIcon i) => switch (i) {
  SummaryIcon.away => Icons.flight_takeoff,
  SummaryIcon.laundry => Icons.local_laundry_service,
  SummaryIcon.fridge => Icons.kitchen,
  SummaryIcon.vacuum => Icons.cleaning_services,
  SummaryIcon.camera => Icons.videocam_outlined,
  SummaryIcon.lock => Icons.lock_outline,
  SummaryIcon.light => Icons.lightbulb_outline,
  SummaryIcon.curtain => Icons.blinds,
  SummaryIcon.offline => Icons.wifi_off,
  SummaryIcon.tv => Icons.tv,
  SummaryIcon.device => Icons.devices_other,
};

/// Top card of the home screen: the one-line summary; tap for the full screen.
class HomeSummaryCard extends StatelessWidget {
  const HomeSummaryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<HubState>();
    final s = hub.summary;
    if (s.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final attention = s.attention.isNotEmpty;
    final bg = attention ? cs.errorContainer : cs.primaryContainer;
    final fg = attention ? cs.onErrorContainer : cs.onPrimaryContainer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        key: const Key('home-summary-card'),
        color: bg,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HomeSummaryScreen())),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(attention ? Icons.notifications_active_outlined : Icons.home_outlined, color: fg),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('집 전체 요약', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg)),
                      const SizedBox(height: 2),
                      Text(
                        s.oneLine(),
                        key: const Key('home-summary-line'),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: fg, fontWeight: FontWeight.w700),
                      ),
                      for (final a in s.items.where((i) => i.icon == SummaryIcon.away))
                        Padding(
                          key: const Key('home-summary-away'),
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.flight_takeoff, size: 16, color: fg),
                              const SizedBox(width: 6),
                              Text(a.title, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: fg)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One card of the summary screen.
class SummaryItemTile extends StatelessWidget {
  const SummaryItemTile({super.key, required this.item});
  final SummaryItem item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (item.level) {
      SummaryLevel.attention => cs.error,
      SummaryLevel.progress => cs.primary,
      SummaryLevel.ok => Colors.green,
    };
    return ListTile(
      key: Key('summary-${item.key}'),
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.15),
        child: Icon(summaryIcon(item.icon), color: color),
      ),
      title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: item.detail == null ? null : Text(item.detail!),
      trailing: item.deviceId == null ? null : const Icon(Icons.chevron_right),
      onTap: item.deviceId == null
          ? null
          : () =>
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => DeviceDetailScreen(deviceId: item.deviceId!))),
    );
  }
}
