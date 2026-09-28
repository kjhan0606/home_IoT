import 'package:flutter/material.dart';

import '../../l10n/ko.dart';
import '../../models/capability_spec.dart';
import '../../models/device.dart';
import '../command.dart';

/// uiHint "slider" (brightness and any 0..100 level).
class LevelSliderCard extends StatefulWidget {
  const LevelSliderCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  @override
  State<LevelSliderCard> createState() => _LevelSliderCardState();
}

class _LevelSliderCardState extends State<LevelSliderCard> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final inst = widget.inst;
    final v = (_drag ?? inst.number('level') ?? 0).toDouble().clamp(0.0, 100.0);
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.brightness_6,
      trailing: Text('${v.round()}%'),
      child: Slider(
        value: v,
        max: 100,
        divisions: 100,
        label: '${v.round()}%',
        onChanged: inst.supports('setLevel') ? (x) => setState(() => _drag = x) : null,
        onChangeEnd: (x) async {
          await sendCommand(context, widget.device.id, inst.key, 'setLevel', params: {'level': x.round()});
          if (mounted) setState(() => _drag = null);
        },
      ),
    );
  }
}

/// uiHint "color-wheel": hue/saturation + colour temperature sliders.
class ColorCard extends StatefulWidget {
  const ColorCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  @override
  State<ColorCard> createState() => _ColorCardState();
}

class _ColorCardState extends State<ColorCard> {
  double? _hue, _sat, _k;

  @override
  Widget build(BuildContext context) {
    final inst = widget.inst;
    final hue = _hue ?? (inst.number('hue') ?? 0).toDouble();
    final sat = _sat ?? (inst.number('saturation') ?? 100).toDouble();
    final k = _k ?? (inst.number('kelvin') ?? 4000).toDouble();
    Future<void> setColor() async {
      await sendCommand(
        context,
        widget.device.id,
        inst.key,
        'setColor',
        params: {'hue': hue.round(), 'saturation': sat.round()},
      );
      if (mounted) setState(() => _hue = _sat = null);
    }

    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.palette_outlined,
      trailing: CircleAvatar(
        radius: 10,
        backgroundColor: HSVColor.fromAHSV(1, hue.clamp(0, 360), sat.clamp(0, 100) / 100, 1).toColor(),
      ),
      child: Column(
        children: [
          if (inst.supports('setColor')) ...[
            Row(
              children: [
                const SizedBox(width: 56, child: Text('색상')),
                Expanded(
                  child: Slider(
                    value: hue.clamp(0, 360),
                    max: 360,
                    onChanged: (v) => setState(() => _hue = v),
                    onChangeEnd: (_) => setColor(),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 56, child: Text('채도')),
                Expanded(
                  child: Slider(
                    value: sat.clamp(0, 100),
                    max: 100,
                    onChanged: (v) => setState(() => _sat = v),
                    onChangeEnd: (_) => setColor(),
                  ),
                ),
              ],
            ),
          ],
          if (inst.supports('setColorTemperature'))
            Row(
              children: [
                const SizedBox(width: 56, child: Text('색온도')),
                Expanded(
                  child: Slider(
                    value: k.clamp(2000, 6500),
                    min: 2000,
                    max: 6500,
                    label: '${k.round()}K',
                    divisions: 45,
                    onChanged: (v) => setState(() => _k = v),
                    onChangeEnd: (v) async {
                      await sendCommand(
                        context,
                        widget.device.id,
                        inst.key,
                        'setColorTemperature',
                        params: {'kelvin': v.round()},
                      );
                      if (mounted) setState(() => _k = null);
                    },
                  ),
                ),
                SizedBox(width: 56, child: Text('${k.round()}K', textAlign: TextAlign.end)),
              ],
            ),
        ],
      ),
    );
  }
}

/// uiHint "readout": sensor readings, cleaning stats, anything read-only.
class ReadoutCard extends StatelessWidget {
  const ReadoutCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  static const _labels = {
    'areaM2': '청소 면적',
    'durationSeconds': '청소 시간',
    'temperature': '온도',
    'humidity': '습도',
    'battery': '배터리',
    'illuminance': '조도',
    'motion': '움직임',
    'contact': '열림 감지',
  };

  static String format(String k, Object? v) {
    if (v == null) return '-';
    return switch (k) {
      'areaM2' when v is num => '${v.toStringAsFixed(1)} m²',
      'durationSeconds' when v is num => Ko.duration(v),
      'battery' || 'humidity' => '$v%',
      'temperature' => '$v°',
      _ => v is bool ? (v ? '예' : '아니오') : v.toString(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final entries = <MapEntry<String, dynamic>>[];
    inst.state.forEach((k, v) {
      if (v is Map) {
        v.forEach((k2, v2) => entries.add(MapEntry(k2.toString(), v2)));
      } else {
        entries.add(MapEntry(k, v));
      }
    });
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.insights,
      child: Column(
        children: [
          for (final e in entries) InfoRow(_labels[e.key] ?? e.key, format(e.key, e.value)),
          if (entries.isEmpty) const Text('데이터 없음'),
        ],
      ),
    );
  }
}

/// Fallback for capabilities without a dedicated widget: shows state and a
/// button per parameter-less action. New hub capabilities still work.
class GenericCapabilityCard extends StatelessWidget {
  const GenericCapabilityCard({super.key, required this.device, required this.inst, this.spec});
  final Device device;
  final CapabilityInstance inst;
  final CapabilitySpec? spec;

  @override
  Widget build(BuildContext context) {
    final simple = inst.actions.where((a) => (spec?.actions[a] ?? const {}).isEmpty).toList();
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.widgets_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in inst.state.entries) InfoRow(e.key, ReadoutCard.format(e.key, e.value)),
          if (simple.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final a in simple)
                  OutlinedButton(onPressed: () => sendCommand(context, device.id, inst.key, a), child: Text(a)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
