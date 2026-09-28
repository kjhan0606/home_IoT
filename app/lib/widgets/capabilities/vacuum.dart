import 'package:flutter/material.dart';

import '../../l10n/ko.dart';
import '../../models/device.dart';
import '../../screens/vacuum_map_screen.dart';
import '../command.dart';

/// uiHint "vacuum-controls": status, battery, errors, start/pause/stop/dock.
class VacuumControlsCard extends StatelessWidget {
  const VacuumControlsCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  @override
  Widget build(BuildContext context) {
    final st = inst.state;
    final battery = inst.number('battery');
    final cs = Theme.of(context).colorScheme;
    final err = st['error'] ?? st['dockError'];
    const buttons = [
      ('start', Icons.play_arrow, '청소 시작'),
      ('pause', Icons.pause, '일시정지'),
      ('stop', Icons.stop, '정지'),
      ('dock', Icons.home, '충전대로'),
    ];
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.cleaning_services,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  Ko.vacuumStatus(st['status']?.toString()),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              if (battery != null) ...[
                Icon(battery > 20 ? Icons.battery_full : Icons.battery_alert, color: battery > 20 ? null : cs.error),
                Text(' ${battery.round()}%'),
              ],
            ],
          ),
          if (err != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(10)),
              child: Text('오류: $err', style: TextStyle(color: cs.onErrorContainer)),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (a, icon, label) in buttons)
                if (inst.supports(a))
                  (a == 'start' ? FilledButton.icon : FilledButton.tonalIcon)(
                    onPressed: () => sendCommand(context, device.id, inst.key, a),
                    icon: Icon(icon),
                    label: Text(label),
                  ),
            ],
          ),
          if (inst.supports('setCleaningMode') && inst.strings('cleaningModes').isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('청소 모드'),
            const SizedBox(height: 4),
            OptionChips(
              options: inst.strings('cleaningModes'),
              selected: st['cleaningMode']?.toString(),
              label: Ko.level,
              onSelected: (m) => sendCommand(context, device.id, inst.key, 'setCleaningMode', params: {'mode': m}),
            ),
          ],
        ],
      ),
    );
  }
}

/// uiHint "mop-controls": water level + mop mode (each only if supported).
class MopCard extends StatelessWidget {
  const MopCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  @override
  Widget build(BuildContext context) {
    final water = inst.strings('waterLevels');
    final modes = inst.strings('mopModes');
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.water_drop_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (inst.supports('setWaterLevel') && water.isNotEmpty) ...[
            const Text('물 양'),
            const SizedBox(height: 4),
            OptionChips(
              options: water,
              selected: inst.state['waterLevel']?.toString(),
              label: Ko.level,
              onSelected: (v) => sendCommand(context, device.id, inst.key, 'setWaterLevel', params: {'level': v}),
            ),
            const SizedBox(height: 8),
          ],
          if (inst.supports('setMopMode') && modes.isNotEmpty) ...[
            const Text('물걸레 모드'),
            const SizedBox(height: 4),
            OptionChips(
              options: modes,
              selected: inst.state['mopMode']?.toString(),
              label: Ko.level,
              onSelected: (v) => sendCommand(context, device.id, inst.key, 'setMopMode', params: {'mode': v}),
            ),
          ],
        ],
      ),
    );
  }
}

/// uiHint "consumables-list": remaining life + reset (with confirmation).
class ConsumablesCard extends StatelessWidget {
  const ConsumablesCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  Future<void> _reset(BuildContext context, String id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('$name 초기화'),
        content: const Text('새 부품으로 교체했을 때만 사용 시간을 초기화하세요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('초기화')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await sendCommand(context, device.id, inst.key, 'reset', params: {'id': id}, successMessage: '$name 초기화됨');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.build_outlined,
      child: Column(
        children: [
          for (final item in inst.objects('items'))
            Builder(
              builder: (context) {
                final id = item['id'].toString();
                final name = Ko.consumable(id, item['name']?.toString());
                final pct = (item['remainingPercent'] as num?)?.toDouble();
                final low = pct != null && pct <= 10;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(child: Text(name)),
                                Text(
                                  pct == null ? '-' : '${pct.round()}%',
                                  style: TextStyle(color: low ? cs.error : null),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            LinearProgressIndicator(
                              value: pct == null ? null : pct / 100,
                              color: low ? cs.error : null,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            if (item['usedHours'] != null)
                              Text('사용 ${item['usedHours']}시간', style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (inst.supports('reset') && item['resettable'] == true)
                        IconButton(
                          tooltip: '$name 초기화',
                          onPressed: () => _reset(context, id, name),
                          icon: const Icon(Icons.restart_alt),
                        ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// uiHint "room-picker": quick room selection without the map.
class RoomPickerCard extends StatefulWidget {
  const RoomPickerCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  @override
  State<RoomPickerCard> createState() => _RoomPickerCardState();
}

class _RoomPickerCardState extends State<RoomPickerCard> {
  final Set<String> _sel = {};
  int _repeat = 1;

  @override
  Widget build(BuildContext context) {
    final inst = widget.inst;
    final rooms = inst.objects('rooms');
    final maxRepeat = (inst.number('maxRepeat') ?? 1).toInt().clamp(1, 9);
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.meeting_room_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final r in rooms)
                FilterChip(
                  label: Text(r['name']?.toString() ?? r['id'].toString()),
                  selected: _sel.contains(r['id'].toString()),
                  onSelected: (v) => setState(() => v ? _sel.add(r['id'].toString()) : _sel.remove(r['id'].toString())),
                ),
            ],
          ),
          const SizedBox(height: 8),
          RepeatSelector(max: maxRepeat, value: _repeat, onChanged: (v) => setState(() => _repeat = v)),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _sel.isEmpty
                ? null
                : () => sendCommand(
                    context,
                    widget.device.id,
                    inst.key,
                    'cleanRooms',
                    params: {'roomIds': _sel.toList(), 'repeat': _repeat},
                    successMessage: '선택한 방 청소를 시작합니다.',
                  ),
            icon: const Icon(Icons.cleaning_services),
            label: Text(_sel.isEmpty ? '방을 선택하세요' : '${_sel.length}개 방 청소'),
          ),
        ],
      ),
    );
  }
}

class RepeatSelector extends StatelessWidget {
  const RepeatSelector({super.key, required this.max, required this.value, required this.onChanged});
  final int max;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    if (max <= 1) return const SizedBox.shrink();
    return Row(
      children: [
        const Text('반복 '),
        const SizedBox(width: 8),
        Expanded(
          child: SegmentedButton<int>(
            segments: [for (var i = 1; i <= max; i++) ButtonSegment(value: i, label: Text('$i회'))],
            selected: {value.clamp(1, max)},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ),
      ],
    );
  }
}

/// uiHint "map-view" (and the map-based zone-drawer / map-tap hints): opens
/// the interactive map screen.
class MapEntryCard extends StatelessWidget {
  const MapEntryCard({super.key, required this.device});
  final Device device;

  @override
  Widget build(BuildContext context) {
    final features = [
      if (device.has('roomCleaning')) '방 선택 청소',
      if (device.has('zoneCleaning')) '구역 그리기',
      if (device.has('goTo')) '길게 눌러 이동',
    ];
    return CapCard(
      title: Ko.cap('vacuumMap'),
      icon: Icons.map_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (features.isNotEmpty) Text(features.join(' · ')),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: const Key('open-map'),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => VacuumMapScreen(deviceId: device.id))),
            icon: const Icon(Icons.map),
            label: const Text('지도 열기'),
          ),
        ],
      ),
    );
  }
}
