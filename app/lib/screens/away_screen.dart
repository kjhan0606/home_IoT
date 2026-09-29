import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../automation/automation_controller.dart';
import '../automation/away.dart';
import '../backend/device_backend.dart';
import '../state/hub_state.dart';

String _two(int n) => n.toString().padLeft(2, '0');
String _ymd(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String _md(String iso) => '${int.parse(iso.substring(5, 7))}/${int.parse(iso.substring(8))}';

/// 휴가/장기 외출 모드: pick the away period, which lights (rooms) and whether curtains take part.
/// The hub (or, in direct mode, this app while it is open) then makes the home look lived in.
/// Only lights and curtains are ever controlled.
class AwayScreen extends StatefulWidget {
  const AwayScreen({super.key});

  @override
  State<AwayScreen> createState() => _AwayScreenState();
}

class _AwayScreenState extends State<AwayScreen> {
  late DateTime _start, _end;
  String _mode = 'random';
  String _wStart = '18:30', _wEnd = '23:00';
  bool _curtains = true;
  String _openAt = '08:00';
  final Set<String> _rooms = {}, _lights = {};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = context.read<AutomationController>();
    final now = context.read<HubState>().now();
    final today = DateTime(now.year, now.month, now.day);
    _start = today;
    _end = today.add(const Duration(days: 6));
    final p = c.away;
    if (p != null) {
      _start = DateTime.parse(p.startDate);
      _end = DateTime.parse(p.endDate);
      _mode = p.mode;
      _wStart = p.windowStart;
      _wEnd = p.windowEnd;
      _curtains = p.curtains.enabled;
      _openAt = p.curtains.openAt;
      _rooms.addAll(p.lightRooms);
      _lights.addAll(p.lightDevices);
    } else {
      // sensible default: every room that has a light
      final lights = context.read<HubState>().devices.where(isAwayLight);
      _rooms.addAll({
        for (final d in lights)
          if (d.meta['room'] is String) d.meta['room'] as String,
      });
      if (_rooms.isEmpty) _lights.addAll(lights.map((d) => d.id));
    }
  }

  TimeOfDay _parse(String s) => TimeOfDay(hour: int.parse(s.substring(0, 2)), minute: int.parse(s.substring(3)));
  String _fmt(TimeOfDay t) => '${_two(t.hour)}:${_two(t.minute)}';

  Future<void> _pickTime(String current, void Function(String) set) async {
    final t = await showTimePicker(context: context, initialTime: _parse(current));
    if (t != null) setState(() => set(_fmt(t)));
  }

  Future<void> _pickRange() async {
    final now = context.read<HubState>().now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year, now.month, now.day).add(const Duration(days: awayMaxDays)),
      initialDateRange: DateTimeRange(start: _start, end: _end),
      helpText: '집을 비우는 기간',
    );
    if (r != null) {
      setState(() {
        _start = r.start;
        _end = r.end;
      });
    }
  }

  Future<void> _save() async {
    final c = context.read<AutomationController>();
    final nav = Navigator.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    final plan = AwayPlan(
      startDate: _ymd(_start),
      endDate: _ymd(_end),
      mode: _mode,
      seed: c.away?.seed ?? Random().nextInt(1000000),
      windowStart: _wStart,
      windowEnd: _wEnd,
      lightRooms: _rooms.toList()..sort(),
      lightDevices: _lights.toList()..sort(),
      curtains: AwayCurtains(enabled: _curtains, openAt: _openAt, closeAt: _wStart),
    );
    try {
      await c.saveAway(plan);
      nav.pop();
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } on BackendException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _stop() async {
    final c = context.read<AutomationController>();
    final nav = Navigator.of(context);
    try {
      await c.stopAway();
      nav.pop();
    } on BackendException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AutomationController>();
    final hub = context.watch<HubState>();
    final t = Theme.of(context).textTheme;
    final lights = hub.devices.where(isAwayLight).toList();
    final rooms = {
      for (final d in lights)
        if (d.meta['room'] is String) d.meta['room'] as String,
    }.toList()..sort();
    final now = hub.now();
    final st = c.away == null ? null : awayStatus(c.away!, now);
    final hasCurtain = hub.devices.any(isAwayCurtain);
    Widget timeTile(Key key, IconData icon, String title, String value, void Function(String) set) => ListTile(
      key: key,
      leading: Icon(icon),
      title: Text(title),
      trailing: Text(value, style: t.titleMedium),
      onTap: () => _pickTime(value, set),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('휴가/장기 외출 모드')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (c.away != null && st != null)
            Card(
              key: const Key('away-status'),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: ListTile(
                leading: const Icon(Icons.flight_takeoff),
                title: Text(switch (st.state) {
                  AwayState.active => st.title,
                  AwayState.scheduled => '휴가 모드 예약됨 (${_md(c.away!.startDate)}부터)',
                  _ => c.awayDone ? '휴가 모드가 끝났습니다' : '휴가 모드 종료',
                }),
                subtitle: Text('${_md(c.away!.startDate)} ~ ${_md(c.away!.endDate)} · ${st.days}일'),
                trailing: TextButton(key: const Key('away-stop'), onPressed: _stop, child: const Text('귀가 · 종료')),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '집을 비운 동안 조명을 켜고 꺼서 사람이 있는 것처럼 보이게 합니다. 조명과 커튼만 제어하며 난방·가전·도어락은 절대 건드리지 않습니다.',
              style: t.bodyMedium,
            ),
          ),
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                c.hubManaged
                    ? '홈 허브가 24시간 실행합니다. 앱이 꺼져 있어도 동작합니다.'
                    : '직접 연결 모드: 앱이 켜져 있는 동안만 동작합니다(최선 노력). 여행 중 안정적으로 쓰려면 홈 허브나 프리미엄 서버가 필요합니다.',
                key: const Key('away-mode-note'),
              ),
            ),
          ),
          ListTile(
            key: const Key('away-period'),
            leading: const Icon(Icons.date_range),
            title: const Text('기간'),
            subtitle: Text('${_ymd(_start)} ~ ${_ymd(_end)} (${_end.difference(_start).inDays + 1}일)'),
            onTap: _pickRange,
          ),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            key: const Key('away-mode'),
            segments: const [
              ButtonSegment(value: 'random', icon: Icon(Icons.shuffle), label: Text('무작위 (자연스럽게)')),
              ButtonSegment(value: 'fixed', icon: Icon(Icons.schedule), label: Text('정해진 시간')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              _mode == 'random'
                  ? '방마다 다른 패턴으로 켜고 끕니다. 거실은 저녁 내내, 주방은 짧게, 욕실은 잠깐씩. 시간은 매일 조금씩 달라집니다.'
                  : '고른 조명을 아래 시간대 동안 계속 켜 둡니다.',
              style: t.bodySmall,
            ),
          ),
          timeTile(const Key('away-window-start'), Icons.wb_twilight, '저녁 시작', _wStart, (v) => _wStart = v),
          timeTile(const Key('away-window-end'), Icons.bedtime_outlined, '저녁 끝 (이후 모두 꺼짐)', _wEnd, (v) => _wEnd = v),
          const Divider(),
          Text('켤 조명', style: t.titleSmall),
          if (lights.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('조명이 없습니다.')),
          if (rooms.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [
                for (final r in rooms)
                  FilterChip(
                    key: Key('away-room-$r'),
                    label: Text(r),
                    selected: _rooms.contains(r),
                    onSelected: (v) => setState(() => v ? _rooms.add(r) : _rooms.remove(r)),
                  ),
              ],
            ),
          for (final d in lights)
            CheckboxListTile(
              key: Key('away-light-${d.id}'),
              dense: true,
              value: _lights.contains(d.id) || _rooms.contains(d.meta['room']),
              title: Text(d.name),
              subtitle: Text('${d.meta['room'] ?? '방 미지정'}'),
              onChanged: _rooms.contains(d.meta['room'])
                  ? null
                  : (v) => setState(() => v == true ? _lights.add(d.id) : _lights.remove(d.id)),
            ),
          const Divider(),
          SwitchListTile(
            key: const Key('away-curtains'),
            title: const Text('커튼도 열고 닫기'),
            subtitle: Text('아침 $_openAt에 열고, 저녁 $_wStart에 닫습니다${hasCurtain ? '' : ' (커튼 기기 없음)'}'),
            value: _curtains,
            onChanged: hasCurtain ? (v) => setState(() => _curtains = v) : null,
          ),
          if (_curtains && hasCurtain)
            timeTile(const Key('away-open-at'), Icons.wb_sunny_outlined, '커튼 여는 시간', _openAt, (v) => _openAt = v),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _error!,
                key: const Key('away-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('away-save'),
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check),
            label: Text(c.away == null ? '휴가 모드 켜기' : '변경 저장'),
          ),
          if (c.hubManaged && c.awaySchedule.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('오늘 저녁 예정', style: t.titleSmall),
            for (final s in c.awaySchedule)
              ListTile(
                dense: true,
                leading: const Icon(Icons.lightbulb_outline),
                title: Text('${s['name']}'),
                subtitle: Text([for (final iv in (s['intervals'] as List)) '${(iv as List)[0]}~${iv[1]}'].join(', ')),
              ),
          ] else if (c.away != null && !c.hubManaged) ...[
            const SizedBox(height: 20),
            Text('오늘 저녁 예정', style: t.titleSmall),
            for (final d in awayPreview(c.away!, lights, now))
              ListTile(
                dense: true,
                leading: const Icon(Icons.lightbulb_outline),
                title: Text(d.$1),
                subtitle: Text(d.$2),
              ),
          ],
        ],
      ),
    );
  }
}
