import 'package:flutter/material.dart';

import '../../l10n/ko.dart';
import '../../models/device.dart';
import '../command.dart';

/// uiHint "curtain-controls" (curtain / blind / shade): open, stop, close and a position slider.
/// Position is 0 (fully closed) .. 100 (fully open) for every brand.
class CurtainCard extends StatefulWidget {
  const CurtainCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  @override
  State<CurtainCard> createState() => _CurtainCardState();
}

class _CurtainCardState extends State<CurtainCard> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final inst = widget.inst;
    final pos = inst.number('position');
    final v = (_drag ?? pos ?? 0).toDouble().clamp(0.0, 100.0);
    Future<void> run(String a) => sendCommand(context, widget.device.id, inst.key, a);
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.blinds,
      trailing: Text(Ko.curtainStatus(inst.state['status']?.toString()), key: const Key('curtain-status')),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (inst.supports('open'))
                FilledButton.icon(
                  key: const Key('curtain-open'),
                  onPressed: () => run('open'),
                  icon: const Icon(Icons.keyboard_arrow_up),
                  label: const Text('열기'),
                ),
              if (inst.supports('stop'))
                OutlinedButton(key: const Key('curtain-stop'), onPressed: () => run('stop'), child: const Text('정지')),
              if (inst.supports('close'))
                FilledButton.tonalIcon(
                  key: const Key('curtain-close'),
                  onPressed: () => run('close'),
                  icon: const Icon(Icons.keyboard_arrow_down),
                  label: const Text('닫기'),
                ),
            ],
          ),
          if (inst.supports('setPosition')) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('닫힘'),
                Expanded(
                  child: Slider(
                    key: const Key('curtain-position'),
                    value: v,
                    max: 100,
                    divisions: 20,
                    label: '${v.round()}% 열림',
                    onChanged: (x) => setState(() => _drag = x),
                    onChangeEnd: (x) async {
                      await sendCommand(
                        context,
                        widget.device.id,
                        inst.key,
                        'setPosition',
                        params: {'position': x.round()},
                      );
                      if (mounted) setState(() => _drag = null);
                    },
                  ),
                ),
                const Text('열림'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
