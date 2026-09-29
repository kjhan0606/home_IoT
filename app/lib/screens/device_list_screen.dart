import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../backend/device_backend.dart';
import '../l10n/ko.dart';
import '../camera/camera_models.dart';
import '../models/device.dart';
import '../state/hub_state.dart';
import '../widgets/camera_thumb.dart';
import '../widgets/command.dart';
import 'add_camera_screen.dart';
import 'camera_screen.dart';
import 'cloud_accounts_screen.dart';
import 'automation_screen.dart';
import 'device_detail_screen.dart';
import 'home_summary_card.dart';
import 'settings_screen.dart';

/// Devices grouped by kind or room, with online state and a quick power toggle.
class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  late String _groupBy = context.read<HubState>().settings.groupBy;
  bool _showPassive = false;

  Future<void> _scan() async {
    final hub = context.read<HubState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await hub.scan();
      messenger.showSnackBar(SnackBar(content: Text('검색 완료: 기기 ${hub.devices.length}개')));
    } on BackendException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('검색 실패: ${e.message}')));
    }
  }

  Future<void> _reload() async {
    try {
      await context.read<HubState>().reload();
    } on BackendException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<HubState>();
    final all = hub.devices;
    final cameras = all.where((d) => d.has('videoStream')).toList();
    final canAddCamera = hub.backend is CameraBackend;
    final controllable = all.where((d) => d.controllable && !d.has('videoStream')).toList();
    final passive = all.where((d) => !d.controllable).toList();
    final groups = <String, List<Device>>{};
    for (final d in controllable) {
      final key = _groupBy == 'room' ? (d.room ?? '방 미지정') : Ko.kind(d.kind);
      groups.putIfAbsent(key, () => []).add(d);
    }
    final hasExample = all.any((d) => d.isExample);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(Ko.appTitle),
            Row(
              children: [
                Icon(Icons.circle, size: 8, color: _statusColor(hub)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    _statusLine(hub),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('scan'),
            tooltip: '기기 검색',
            onPressed: hub.scanning ? null : _scan,
            icon: hub.scanning
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.radar),
          ),
          if (canAddCamera)
            IconButton(
              key: const Key('add-camera'),
              tooltip: '카메라 추가',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddCameraScreen())),
              icon: const Icon(Icons.add_a_photo_outlined),
            ),
          IconButton(
            key: const Key('open-automation'),
            tooltip: '자동화 규칙',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AutomationScreen())),
            icon: const Icon(Icons.auto_mode),
          ),
          IconButton(
            tooltip: '설정',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            for (final e in hub.warnings.entries)
              _Banner(
                key: Key('warning-${e.key}'),
                icon: Icons.warning_amber_rounded,
                text: e.value,
                action: TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CloudAccountsScreen())),
                  child: const Text('토큰 설정'),
                ),
              ),
            if (hub.mode == BackendKind.directCloud &&
                hub.smartThingsLikelyExpired &&
                !hub.warnings.containsKey('smartthings'))
              _Banner(
                key: const Key('st-expired-banner'),
                icon: Icons.schedule,
                text: 'SmartThings 토큰은 24시간 뒤 만료됩니다. 입력한 지 24시간이 지났으니 새 토큰이 필요할 수 있습니다.',
                action: TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CloudAccountsScreen())),
                  child: const Text('토큰 설정'),
                ),
              ),
            const HomeSummaryCard(),
            if (hasExample) const _Banner(icon: Icons.science_outlined, text: '허브가 데모 모드입니다. 표시된 기기는 예시 데이터입니다.'),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'kind', icon: Icon(Icons.category_outlined), label: Text('종류별')),
                  ButtonSegment(value: 'room', icon: Icon(Icons.meeting_room_outlined), label: Text('방별')),
                ],
                selected: {_groupBy},
                onSelectionChanged: (s) {
                  setState(() => _groupBy = s.first);
                  hub.settings.setGroupBy(s.first);
                },
              ),
            ),
            if (cameras.isNotEmpty) ...[
              _Header('카메라', cameras.length),
              CameraGrid(cameras: cameras),
            ],
            if (controllable.isEmpty && cameras.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    const Icon(Icons.devices_other, size: 48),
                    const SizedBox(height: 12),
                    const Text('제어 가능한 기기가 없습니다.', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: hub.scanning ? null : _scan,
                      icon: const Icon(Icons.radar),
                      label: const Text('기기 검색'),
                    ),
                  ],
                ),
              ),
            for (final g in groups.entries) ...[
              _Header(g.key, g.value.length),
              for (final d in g.value) DeviceTile(device: d),
            ],
            if (passive.isNotEmpty)
              ExpansionTile(
                initiallyExpanded: _showPassive,
                onExpansionChanged: (v) => _showPassive = v,
                title: Text('네트워크의 다른 기기 (${passive.length})'),
                subtitle: const Text('제어는 지원되지 않음'),
                children: [for (final d in passive) DeviceTile(device: d)],
              ),
          ],
        ),
      ),
    );
  }
}

Color _statusColor(HubState hub) {
  final b = hub.backend;
  if (b == null) return Colors.grey;
  if (b.hasEventStream) return hub.liveConnected ? Colors.green : Colors.orange;
  return hub.warnings.isEmpty && hub.error == null ? Colors.green : Colors.orange;
}

String _statusLine(HubState hub) {
  final b = hub.backend;
  if (b == null) return '';
  final parts = [b.title, if (b.subtitle != null && b.subtitle!.isNotEmpty) b.subtitle!];
  final line = parts.join(' · ');
  if (b.hasEventStream && !hub.liveConnected) return '$line (실시간 연결 대기)';
  if (!b.hasEventStream && hub.error != null) return '$line (불러오기 실패)';
  return line;
}

class _Header extends StatelessWidget {
  const _Header(this.title, this.count);
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      '$title  $count',
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, color: cs.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: cs.onTertiaryContainer)),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// One-line summary built from canonical state only.
String deviceSummary(Device d) {
  final parts = <String>[];
  final vac = d.cap('vacuum');
  if (vac != null) {
    parts.add(Ko.vacuumStatus(vac.state['status']?.toString()));
    if (vac.number('battery') != null) parts.add('배터리 ${vac.number('battery')!.round()}%');
  }
  for (final k in ['washer', 'dryer']) {
    final c = d.cap(k);
    if (c == null) continue;
    parts.add(Ko.machineState(c.state['machineState']?.toString()));
    final rem = c.number('remainingMinutes');
    if (rem != null) parts.add('${rem.round()}분 남음');
  }
  final fr = d.cap('refrigeration');
  if (fr != null) {
    final u = fr.state['unit'] ?? 'C';
    if (fr.number('fridgeTemperature') != null) parts.add('냉장 ${fr.number('fridgeTemperature')}°$u');
    if (fr.number('freezerTemperature') != null) parts.add('냉동 ${fr.number('freezerTemperature')}°$u');
    if (fr.state['doorOpen'] == true) parts.add('문 열림');
  }
  final lock = d.cap('lock');
  if (lock != null) parts.add(lock.state['locked'] == true ? '잠김' : '열림');
  final vol = d.cap('volume');
  if (vol != null && d.powerOn == true && vol.number('level') != null) parts.add('볼륨 ${vol.number('level')}');
  if (parts.isEmpty) parts.add(d.controllable ? Ko.kind(d.kind) : (d.ip ?? Ko.kind(d.kind)));
  return parts.join(' · ');
}

class DeviceTile extends StatelessWidget {
  const DeviceTile({super.key, required this.device});
  final Device device;

  @override
  Widget build(BuildContext context) {
    final d = device;
    final power = d.cap('power');
    final canToggle =
        power != null && (power.supports('toggle') || (power.supports('turnOn') && power.supports('turnOff')));
    return ListTile(
      key: Key('device-${d.id}'),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(child: Icon(Ko.kindIcon(d.kind))),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: d.reachable ? Colors.green : Colors.grey,
                border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${d.reachable ? '온라인' : '오프라인'} · ${deviceSummary(d)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: canToggle
          ? Switch(
              key: Key('power-${d.id}'),
              value: d.powerOn ?? false,
              onChanged: (v) => sendCommand(
                context,
                d.id,
                'power',
                power.supports(v ? 'turnOn' : 'turnOff') ? (v ? 'turnOn' : 'turnOff') : 'toggle',
              ),
            )
          : (d.controllable ? const Icon(Icons.chevron_right) : null),
      onTap: d.controllable || d.capabilities.isNotEmpty
          ? () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => d.has('videoStream') ? CameraScreen(deviceId: d.id) : DeviceDetailScreen(deviceId: d.id),
              ),
            )
          : null,
    );
  }
}
