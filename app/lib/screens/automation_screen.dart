import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../automation/automation_controller.dart';
import '../automation/st_rules_exporter.dart';
import '../automation/templates.dart';
import '../backend/device_backend.dart';
import '../models/automation.dart';
import '../state/hub_state.dart';
import '../automation/away.dart';
import 'away_screen.dart';

IconData _templateIcon(String k) => switch (k) {
  'bedtime' => Icons.bedtime_outlined,
  'wb_sunny' => Icons.wb_sunny_outlined,
  'alarm' => Icons.alarm,
  'logout' => Icons.logout,
  'login' => Icons.login,
  'lock' => Icons.lock_outline,
  _ => Icons.auto_mode,
};

/// Rules: list with on/off switches, create from templates, run log.
class AutomationScreen extends StatefulWidget {
  const AutomationScreen({super.key});

  @override
  State<AutomationScreen> createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AutomationController>().load());
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } on StRuleUnsupported catch (e) {
      _snack('Samsung 규칙으로 옮길 수 없습니다: ${e.message}');
    } on BackendException catch (e) {
      _snack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AutomationController>();
    final hub = context.watch<HubState>();
    final t = Theme.of(context).textTheme;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('자동화 규칙'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '규칙'),
              Tab(text: '실행 기록'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('add-rule'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RuleTemplatesScreen())),
          icon: const Icon(Icons.add),
          label: const Text('규칙 추가'),
        ),
        body: TabBarView(
          children: [
            RefreshIndicator(
              onRefresh: c.load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  _ModeBanner(controller: c),
                  if (c.away != null) _AwayCard(controller: c, now: hub.now()),
                  if (c.error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(c.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  if (c.rules.isEmpty && !c.loading)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Column(
                        children: [
                          Icon(Icons.auto_mode, size: 48),
                          SizedBox(height: 12),
                          Text('아직 규칙이 없습니다.\n아래 "규칙 추가"에서 템플릿으로 쉽게 만들 수 있어요.', textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  for (final r in c.rules)
                    Card(
                      key: Key('rule-${r.id}'),
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: ListTile(
                        leading: Icon(
                          _templateIcon(templateById(r.template ?? '')?.icon ?? ''),
                          color: r.enabled ? null : Theme.of(context).disabledColor,
                        ),
                        title: Text(r.name, style: t.titleSmall),
                        subtitle: Text(describeRule(r) + (c.exported.containsKey(r.id) ? '\nSamsung 클라우드에서 실행 중' : '')),
                        isThreeLine: true,
                        trailing: Switch(
                          key: Key('rule-switch-${r.id}'),
                          value: r.enabled,
                          onChanged: (v) => _guard(() => c.setEnabled(r.id, v)),
                        ),
                        onTap: () => _ruleMenu(context, c, r),
                      ),
                    ),
                  _Signals(controller: c, hub: hub),
                ],
              ),
            ),
            _RunLog(controller: c),
          ],
        ),
      ),
    );
  }

  Future<void> _ruleMenu(BuildContext context, AutomationController c, Rule r) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(r.name), subtitle: Text(describeRule(r))),
            if (c.canExportToSamsung && !c.exported.containsKey(r.id))
              ListTile(
                key: const Key('rule-export'),
                leading: const Icon(Icons.cloud_upload_outlined),
                title: const Text('Samsung 클라우드에 등록'),
                subtitle: const Text('앱이 꺼져 있어도 삼성이 대신 실행합니다 (SmartThings 기기만)'),
                onTap: () => Navigator.pop(ctx, 'export'),
              ),
            if (c.exported.containsKey(r.id))
              ListTile(
                leading: const Icon(Icons.cloud_off_outlined),
                title: const Text('Samsung 클라우드에서 해제'),
                onTap: () => Navigator.pop(ctx, 'unexport'),
              ),
            ListTile(
              key: const Key('rule-delete'),
              leading: const Icon(Icons.delete_outline),
              title: const Text('삭제'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'delete':
        await _guard(() => c.delete(r.id));
      case 'export':
        await _guard(() async {
          final preview = await c.previewSamsung(r);
          if (!context.mounted) return;
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Samsung 클라우드에 등록'),
              content: Text(
                '이 규칙을 SmartThings에 등록합니다. 등록 후에는 삼성 서버가 실행하며 앱은 이 규칙을 직접 실행하지 않습니다.\n'
                '${preview.notes.map((n) => '• $n').join('\n')}\n'
                '토큰에 규칙 권한(r/w/x:rules)이 필요합니다.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('등록')),
              ],
            ),
          );
          if (ok == true) {
            await c.registerInSamsung(r);
            _snack('Samsung 클라우드에 등록했습니다.');
          }
        });
      case 'unexport':
        await _guard(() => c.removeFromSamsung(r));
    }
  }
}

/// Shown on the rules list while a 휴가 모드 plan exists.
class _AwayCard extends StatelessWidget {
  const _AwayCard({required this.controller, required this.now});
  final AutomationController controller;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final p = controller.away!;
    final st = awayStatus(p, now);
    final done = controller.awayDone || st.state == AwayState.finished;
    return Card(
      key: const Key('away-card'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.flight_takeoff),
        title: Text(done ? '휴가 모드 종료' : (st.state == AwayState.scheduled ? '휴가 모드 예약됨' : st.title)),
        subtitle: Text(
          '${p.startDate.substring(5)} ~ ${p.endDate.substring(5)} · ${p.mode == 'random' ? '무작위' : '정해진 시간'}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AwayScreen())),
      ),
    );
  }
}

class _ModeBanner extends StatelessWidget {
  const _ModeBanner({required this.controller});
  final AutomationController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hubMode = controller.hubManaged;
    return Container(
      key: const Key('automation-mode-banner'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: hubMode ? cs.primaryContainer : cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            hubMode ? Icons.hub_outlined : Icons.phone_iphone,
            color: hubMode ? cs.onPrimaryContainer : cs.onTertiaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hubMode
                  ? '규칙은 홈 허브에서 24시간 실행됩니다. 앱이 꺼져 있어도 동작합니다.'
                  : '직접 연결 모드: 규칙은 앱이 켜져 있는 동안에만 실행됩니다(최선 노력). '
                        '앱이 꺼져 있을 때도 실행하려면 홈 허브나 프리미엄 서버를 쓰거나, '
                        'SmartThings 기기라면 "Samsung 클라우드에 등록"을 사용하세요.',
              style: TextStyle(color: hubMode ? cs.onPrimaryContainer : cs.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _Signals extends StatelessWidget {
  const _Signals({required this.controller, required this.hub});
  final AutomationController controller;
  final HubState hub;

  @override
  Widget build(BuildContext context) {
    final events = {
      for (final r in controller.rules)
        if (r.enabled && r.trigger.type == TriggerType.event) r.trigger.name!,
    };
    if (events.isEmpty) return const SizedBox.shrink();
    const labels = {'leaving': '외출', 'arriving': '귀가', 'wake': '기상'};
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('신호 보내기', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            '위치 자동 감지는 아직 없습니다. 버튼을 누르거나 휴대폰 단축어로 신호를 보내면 해당 규칙이 실행됩니다.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final e in events)
                ActionChip(
                  key: Key('signal-$e'),
                  avatar: const Icon(Icons.send, size: 16),
                  label: Text(labels[e] ?? e),
                  onPressed: () async {
                    final n = await controller.fireEvent(e);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(n > 0 ? '규칙 $n개를 실행했습니다.' : '실행할 규칙이 없습니다.')));
                    }
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String statusText(String s) => switch (s) {
  'ok' => '성공',
  'partial' => '일부 실패',
  'error' => '실패',
  'skipped' => '이미 그 상태라 건너뜀',
  'no-targets' => '대상 기기 없음',
  _ => s,
};

String _skipText(String s) => switch (s) {
  'already-closed' => '이미 닫혀 있음',
  'already-open' => '이미 열려 있음',
  'already-on' => '이미 켜져 있음',
  'already-off' => '이미 꺼져 있음',
  'already-there' => '이미 그 위치',
  'already-locked' => '이미 잠겨 있음',
  'already-unlocked' => '이미 열려 있음',
  _ => s,
};

class _RunLog extends StatelessWidget {
  const _RunLog({required this.controller});
  final AutomationController controller;

  @override
  Widget build(BuildContext context) {
    final log = controller.log;
    if (log.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('아직 실행된 규칙이 없습니다.', key: Key('log-empty')),
        ),
      );
    }
    String hm(DateTime d) {
      final l = d.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(l.month)}/${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
    }

    return ListView(
      children: [
        for (final e in log)
          ExpansionTile(
            key: Key('log-${e.ruleId}-${e.time.millisecondsSinceEpoch}'),
            leading: Icon(
              e.status == 'ok' || e.status == 'skipped' ? Icons.check_circle_outline : Icons.error_outline,
              color: e.status == 'ok' || e.status == 'skipped' ? Colors.green : Theme.of(context).colorScheme.error,
            ),
            title: Text(e.ruleName),
            subtitle: Text('${hm(e.time)} · ${e.reason} · ${statusText(e.status)}'),
            children: [
              for (final s in e.steps)
                ListTile(
                  dense: true,
                  title: Text('${s.deviceName}  ${s.capability}.${s.action}'),
                  subtitle: Text(s.skip != null ? _skipText(s.skip!) : (s.ok ? '보냄' : '실패: ${s.error}')),
                ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextButton(onPressed: controller.clearLog, child: const Text('기록 지우기')),
        ),
      ],
    );
  }
}

/// Template picker -> small form (times) -> saved rule.
class RuleTemplatesScreen extends StatelessWidget {
  const RuleTemplatesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final devices = context.watch<HubState>().devices;
    return Scaffold(
      appBar: AppBar(title: const Text('규칙 추가')),
      body: ListView(
        children: [
          const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('템플릿을 고르세요. 필요한 기기가 없으면 흐리게 표시됩니다.')),
          ListTile(
            key: const Key('template-away-mode'),
            enabled: devices.any(isAwayLight),
            leading: const Icon(Icons.flight_takeoff),
            title: const Text('휴가/장기 외출 모드'),
            subtitle: Text(
              devices.any(isAwayLight)
                  ? '집을 비운 동안 조명(과 커튼)을 자연스럽게 켜고 꺼서 빈집으로 보이지 않게 합니다.'
                  : '집을 비운 동안 조명(과 커튼)을 자연스럽게 켜고 꺼서 빈집으로 보이지 않게 합니다.\n(필요한 기기가 없습니다)',
            ),
            isThreeLine: !devices.any(isAwayLight),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const AwayScreen())),
          ),
          for (final t in ruleTemplates)
            Builder(
              builder: (context) {
                final ok = t.available(devices);
                return ListTile(
                  key: Key('template-${t.id}'),
                  enabled: ok,
                  leading: Icon(_templateIcon(t.icon)),
                  title: Text(t.title),
                  subtitle: Text(ok ? t.description : '${t.description}\n(필요한 기기가 없습니다)'),
                  isThreeLine: !ok,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: ok
                      ? () =>
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => RuleTemplateForm(template: t)))
                      : null,
                );
              },
            ),
        ],
      ),
    );
  }
}

class RuleTemplateForm extends StatefulWidget {
  const RuleTemplateForm({super.key, required this.template});
  final RuleTemplate template;

  @override
  State<RuleTemplateForm> createState() => _RuleTemplateFormState();
}

class _RuleTemplateFormState extends State<RuleTemplateForm> {
  late String _time = widget.template.defaultTime;
  String _start = '22:00', _end = '02:00';
  bool _saving = false;

  TimeOfDay _parse(String s) => TimeOfDay(hour: int.parse(s.substring(0, 2)), minute: int.parse(s.substring(3)));
  String _fmt(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pick(String current, void Function(String) set) async {
    final t = await showTimePicker(context: context, initialTime: _parse(current));
    if (t != null) setState(() => set(_fmt(t)));
  }

  Future<void> _save() async {
    final c = context.read<AutomationController>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await c.save(widget.template.build(newRuleId(), time: _time, windowStart: _start, windowEnd: _end));
      nav
        ..pop() // form
        ..pop(); // template list -> back to the rule list
    } on BackendException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.template;
    Widget timeTile(Key key, IconData icon, String title, String value, void Function(String) set) => ListTile(
      key: key,
      leading: Icon(icon),
      title: Text(title),
      trailing: Text(value, style: Theme.of(context).textTheme.titleMedium),
      onTap: () => _pick(value, set),
    );
    return Scaffold(
      appBar: AppBar(title: Text(t.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(t.description, style: Theme.of(context).textTheme.bodyLarge),
          if (t.hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t.hint!, style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 16),
          if (t.needsWindow) ...[
            timeTile(const Key('window-start'), Icons.bedtime_outlined, '취침 시간대 시작', _start, (v) => _start = v),
            timeTile(const Key('window-end'), Icons.wb_twilight, '취침 시간대 끝', _end, (v) => _end = v),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('끝 시간이 시작보다 이르면 다음 날 새벽까지로 계산합니다 (예: 22:00~02:00).'),
            ),
          ],
          if (t.needsTime) timeTile(const Key('rule-time'), Icons.alarm, '기상 시간', _time, (v) => _time = v),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('save-rule'),
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check),
            label: const Text('이 규칙 저장'),
          ),
        ],
      ),
    );
  }
}
