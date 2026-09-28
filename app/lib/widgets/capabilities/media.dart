import 'package:flutter/material.dart';

import '../../l10n/ko.dart';
import '../../models/capability_spec.dart';
import '../../models/device.dart';
import '../command.dart';

/// uiHint "toggle": power (turnOn/turnOff/toggle) or lock (lock/unlock).
class ToggleCard extends StatelessWidget {
  const ToggleCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  @override
  Widget build(BuildContext context) {
    final isLock = inst.state.containsKey('locked') || inst.supports('lock');
    final on = isLock ? inst.state['locked'] == true : inst.state['switch'] == 'on';
    String? actionFor(bool target) {
      if (isLock) return target ? (inst.supports('lock') ? 'lock' : null) : (inst.supports('unlock') ? 'unlock' : null);
      final a = target ? 'turnOn' : 'turnOff';
      return inst.supports(a) ? a : (inst.supports('toggle') ? 'toggle' : null);
    }

    final label = isLock ? (on ? '잠김' : '열림') : (on ? '켜짐' : '꺼짐');
    return CapCard(
      title: Ko.cap(inst.key),
      icon: isLock ? (on ? Icons.lock : Icons.lock_open) : Icons.power_settings_new,
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.headlineSmall)),
          if (!isLock && inst.supports('turnOn') && inst.supports('turnOff')) ...[
            OutlinedButton(
              onPressed: () => sendCommand(context, device.id, inst.key, 'turnOff'),
              child: const Text('끄기'),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: () => sendCommand(context, device.id, inst.key, 'turnOn'), child: const Text('켜기')),
          ] else
            Switch(
              value: on,
              onChanged: actionFor(!on) == null
                  ? null
                  : (v) => sendCommand(context, device.id, inst.key, actionFor(v)!),
            ),
        ],
      ),
    );
  }
}

/// uiHint "slider+mute": volume +/-, mute, and a slider when setLevel exists.
class VolumeCard extends StatefulWidget {
  const VolumeCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  @override
  State<VolumeCard> createState() => _VolumeCardState();
}

class _VolumeCardState extends State<VolumeCard> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final inst = widget.inst;
    final id = widget.device.id;
    final level = inst.number('level');
    final muted = inst.state['muted'] == true;
    return CapCard(
      title: Ko.cap(inst.key),
      icon: muted ? Icons.volume_off : Icons.volume_up,
      trailing: level == null ? null : Text('${(_drag ?? level).round()}'),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (inst.supports('volumeDown'))
                IconButton.filledTonal(
                  iconSize: 32,
                  tooltip: '볼륨 낮추기',
                  onPressed: () => sendCommand(context, id, inst.key, 'volumeDown'),
                  icon: const Icon(Icons.remove),
                ),
              if (inst.supports('mute') || inst.supports('unmute'))
                IconButton.filledTonal(
                  iconSize: 32,
                  tooltip: muted ? '음소거 해제' : '음소거',
                  isSelected: muted,
                  onPressed: () =>
                      sendCommand(context, id, inst.key, muted && inst.supports('unmute') ? 'unmute' : 'mute'),
                  icon: Icon(muted ? Icons.volume_off : Icons.volume_mute),
                ),
              if (inst.supports('volumeUp'))
                IconButton.filledTonal(
                  iconSize: 32,
                  tooltip: '볼륨 높이기',
                  onPressed: () => sendCommand(context, id, inst.key, 'volumeUp'),
                  icon: const Icon(Icons.add),
                ),
            ],
          ),
          if (inst.supports('setLevel'))
            Slider(
              value: (_drag ?? level ?? 0).toDouble().clamp(0, 100),
              max: 100,
              divisions: 100,
              label: '${(_drag ?? level ?? 0).round()}',
              onChanged: (v) => setState(() => _drag = v),
              onChangeEnd: (v) async {
                await sendCommand(context, id, inst.key, 'setLevel', params: {'level': v.round()});
                if (mounted) setState(() => _drag = null);
              },
            ),
        ],
      ),
    );
  }
}

/// uiHint "stepper": channel up/down + direct entry.
class ChannelCard extends StatelessWidget {
  const ChannelCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  Future<void> _enter(BuildContext context) async {
    final ctl = TextEditingController();
    final ch = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('채널 번호'),
        content: TextField(controller: ctl, autofocus: true, keyboardType: TextInputType.number),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('이동')),
        ],
      ),
    );
    if (ch != null && ch.isNotEmpty && context.mounted) {
      await sendCommand(context, device.id, inst.key, 'setChannel', params: {'channel': ch});
    }
  }

  @override
  Widget build(BuildContext context) {
    final ch = inst.state['channel']?.toString();
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.live_tv,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (inst.supports('channelDown'))
            IconButton.filledTonal(
              iconSize: 32,
              tooltip: '이전 채널',
              onPressed: () => sendCommand(context, device.id, inst.key, 'channelDown'),
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
          InkWell(
            onTap: inst.supports('setChannel') ? () => _enter(context) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(ch ?? '-', style: Theme.of(context).textTheme.headlineMedium),
            ),
          ),
          if (inst.supports('channelUp'))
            IconButton.filledTonal(
              iconSize: 32,
              tooltip: '다음 채널',
              onPressed: () => sendCommand(context, device.id, inst.key, 'channelUp'),
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
        ],
      ),
    );
  }
}

/// uiHint "picker": any "choose one of a list" capability. Which state field
/// holds the options and which action/param to call is read from the spec, so
/// e.g. mediaInput (sources/selected, select{source}) and fanSpeed
/// (levels/level, setLevel{level}) share this widget.
class PickerCard extends StatelessWidget {
  const PickerCard({super.key, required this.device, required this.inst, this.spec});
  final Device device;
  final CapabilityInstance inst;
  final CapabilitySpec? spec;

  @override
  Widget build(BuildContext context) {
    final listField = inst.state.entries.firstWhere((e) => e.value is List, orElse: () => const MapEntry('', null));
    final options = listField.value is List ? inst.strings(listField.key) : const <String>[];
    final currentField = inst.state.entries
        .firstWhere(
          (e) => e.key != listField.key && (e.value is String || e.value == null),
          orElse: () => const MapEntry('', null),
        )
        .key;
    final action = inst.actions.isNotEmpty ? inst.actions.first : null;
    final param = (action != null ? spec?.actions[action]?.keys.firstOrNull : null) ?? currentField;
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.tune,
      child: options.isEmpty
          ? const Text('선택 가능한 항목이 없습니다.')
          : OptionChips(
              options: options,
              selected: inst.state[currentField]?.toString(),
              label: Ko.level,
              onSelected: action == null
                  ? null
                  : (o) => sendCommand(context, device.id, inst.key, action, params: {param: o}),
            ),
    );
  }
}

/// uiHint "transport": play/pause/stop/previous/next.
class TransportCard extends StatelessWidget {
  const TransportCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  static const _icons = {
    'previous': Icons.skip_previous,
    'play': Icons.play_arrow,
    'pause': Icons.pause,
    'stop': Icons.stop,
    'next': Icons.skip_next,
  };
  static const _labels = {'previous': '이전', 'play': '재생', 'pause': '일시정지', 'stop': '정지', 'next': '다음'};

  @override
  Widget build(BuildContext context) => CapCard(
    title: Ko.cap(inst.key),
    icon: Icons.play_circle_outline,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final a in _icons.keys)
          if (inst.supports(a))
            IconButton.filledTonal(
              tooltip: _labels[a],
              iconSize: 28,
              onPressed: () => sendCommand(context, device.id, inst.key, a),
              icon: Icon(_icons[a]),
            ),
      ],
    ),
  );
}

/// uiHint "app-grid".
class AppGridCard extends StatelessWidget {
  const AppGridCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  @override
  Widget build(BuildContext context) {
    final apps = inst.strings('apps');
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.apps,
      child: apps.isEmpty
          ? const Text('등록된 앱이 없습니다.')
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in apps)
                  ActionChip(
                    avatar: const Icon(Icons.open_in_new, size: 16),
                    label: Text(a),
                    onPressed: () => sendCommand(context, device.id, inst.key, 'open', params: {'app': a}),
                  ),
              ],
            ),
    );
  }
}
