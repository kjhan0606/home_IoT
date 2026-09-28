import 'package:flutter/material.dart';

import '../../l10n/ko.dart';
import '../../models/device.dart';
import '../command.dart';

/// uiHint "laundry-cycle" (washer, dryer): state, phase, remaining time,
/// start/pause/stop. Remote start is refused by the appliance (HTTP 403) until
/// the user presses the machine's Remote Start button.
class LaundryCard extends StatelessWidget {
  const LaundryCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  @override
  Widget build(BuildContext context) {
    final st = inst.state;
    final remote = st['remoteControlEnabled'];
    final remaining = inst.number('remainingMinutes');
    final completion = DateTime.tryParse(st['completionTime']?.toString() ?? '')?.toLocal();
    final cs = Theme.of(context).colorScheme;
    Future<void> run(String a) =>
        sendCommand(context, device.id, inst.key, a, forbiddenMessage: a == 'start' ? Ko.remoteStartHelp : null);
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Ko.kindIcon(inst.key),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoRow('상태', Ko.machineState(st['machineState']?.toString())),
          InfoRow('진행 단계', Ko.jobState(st['jobState']?.toString())),
          InfoRow('남은 시간', remaining == null ? '-' : Ko.duration(remaining * 60)),
          if (completion != null)
            InfoRow(
              '완료 예정',
              '${completion.hour.toString().padLeft(2, '0')}:${completion.minute.toString().padLeft(2, '0')}',
            ),
          InfoRow(
            '원격 제어',
            remote == null ? '알 수 없음' : (remote == true ? '켜짐' : '꺼짐'),
            valueColor: remote == false ? cs.error : null,
          ),
          if (remote == false) ...[
            const SizedBox(height: 8),
            Container(
              key: const Key('remote-start-banner'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(12)),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: cs.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(Ko.remoteStartHelp, style: TextStyle(color: cs.onErrorContainer)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              if (inst.supports('start'))
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => run('start'),
                    icon: const Icon(Icons.play_arrow),
                    label: const FittedBox(fit: BoxFit.scaleDown, child: Text('시작')),
                  ),
                ),
              if (inst.supports('pause')) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => run('pause'),
                    icon: const Icon(Icons.pause),
                    label: const FittedBox(fit: BoxFit.scaleDown, child: Text('일시정지')),
                  ),
                ),
              ],
              if (inst.supports('stop')) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => run('stop'),
                    icon: const Icon(Icons.stop),
                    label: const FittedBox(fit: BoxFit.scaleDown, child: Text('정지')),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// uiHint "fridge-panel": temperatures, setpoints, doors, rapid cool/freeze.
class FridgeCard extends StatelessWidget {
  const FridgeCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  String _t(num? v, String unit) => v == null ? '-' : '${v.toStringAsFixed(v % 1 == 0 ? 0 : 1)}°$unit';

  Widget _setpoint(BuildContext context, String label, String field, String action, num? measured, String unit) {
    final sp = inst.number(field);
    final can = inst.supports(action) && sp != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleSmall),
                Text('현재 ${_t(measured, unit)}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          IconButton.outlined(
            tooltip: '$label 설정 온도 낮추기',
            onPressed: can
                ? () => sendCommand(context, device.id, inst.key, action, params: {'temperature': sp - 1})
                : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 72,
            child: Text(_t(sp, unit), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          ),
          IconButton.outlined(
            tooltip: '$label 설정 온도 높이기',
            onPressed: can
                ? () => sendCommand(context, device.id, inst.key, action, params: {'temperature': sp + 1})
                : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unit = inst.state['unit']?.toString() ?? 'C';
    final doors = Map<String, dynamic>.from((inst.state['doors'] as Map?) ?? const {});
    final anyOpen = inst.state['doorOpen'];
    const doorNames = {'fridge': '냉장실', 'freezer': '냉동실', 'main': '메인', 'cvroom': '변온실'};
    final cs = Theme.of(context).colorScheme;
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.kitchen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _setpoint(context, '냉장실', 'fridgeSetpoint', 'setFridgeSetpoint', inst.number('fridgeTemperature'), unit),
          _setpoint(context, '냉동실', 'freezerSetpoint', 'setFreezerSetpoint', inst.number('freezerTemperature'), unit),
          const Divider(),
          InfoRow(
            '문',
            anyOpen == null ? '알 수 없음' : (anyOpen == true ? '열림' : '닫힘'),
            valueColor: anyOpen == true ? cs.error : null,
          ),
          for (final e in doors.entries)
            InfoRow(
              '  ${doorNames[e.key] ?? e.key}',
              e.value == true ? '열림' : '닫힘',
              valueColor: e.value == true ? cs.error : null,
            ),
          const Divider(),
          for (final (field, action, label) in const [
            ('rapidCooling', 'setRapidCooling', '급냉'),
            ('rapidFreezing', 'setRapidFreezing', '급속 냉동'),
          ])
            if (inst.supports(action) || inst.state[field] != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label),
                value: inst.state[field] == true,
                onChanged: inst.supports(action)
                    ? (v) => sendCommand(context, device.id, inst.key, action, params: {'enabled': v})
                    : null,
              ),
        ],
      ),
    );
  }
}
