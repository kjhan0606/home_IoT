import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/hub_state.dart';
import '../summary/home_summary.dart';
import 'automation_screen.dart';
import 'home_summary_card.dart';

/// "집 전체 요약": cards grouped into 확인 필요 / 진행 중 / 이상 없음.
class HomeSummaryScreen extends StatelessWidget {
  const HomeSummaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<HubState>();
    final s = hub.summary;
    Widget section(String title, IconData icon, Color color, List<SummaryItem> items) {
      if (items.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 6),
                Text('$title  ${items.length}', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: color)),
              ],
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(children: [for (final i in items) SummaryItemTile(item: i)]),
          ),
        ],
      );
    }

    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('집 전체 요약'),
        actions: [
          IconButton(
            tooltip: '자동화 규칙',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AutomationScreen())),
            icon: const Icon(Icons.auto_mode),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => hub.reload(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                s.oneLine(max: 8),
                key: const Key('summary-oneline'),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            section('확인 필요', Icons.priority_high, cs.error, s.attention),
            section('진행 중', Icons.autorenew, cs.primary, s.progress),
            section('이상 없음', Icons.check_circle_outline, Colors.green, s.ok),
            if (s.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('표시할 기기가 없습니다.')),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Text(
                '앱이 켜져 있는 동안 새 알림이 뜹니다. 앱이 꺼져 있을 때의 푸시 알림은 프리미엄 서버가 필요합니다.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
