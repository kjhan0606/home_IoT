import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../backend/device_backend.dart';
import '../backend/direct/cloud_provider.dart';
import '../state/hub_state.dart';

/// Sends a canonical command and reports errors in Korean. Returns true on success.
/// [forbiddenMessage] replaces the hub's text for HTTP 403 (e.g. remote start off).
Future<bool> sendCommand(
  BuildContext context,
  String deviceId,
  String capability,
  String action, {
  Map<String, dynamic> params = const {},
  String? forbiddenMessage,
  String? successMessage,
}) async {
  final hub = context.read<HubState>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await hub.command(deviceId, capability, action, params);
    if (successMessage != null) {
      messenger?.showSnackBar(SnackBar(content: Text(successMessage)));
    }
    return true;
  } on BackendException catch (e) {
    final msg = switch (e.statusCode) {
      403 => forbiddenMessage ?? '기기가 명령을 거부했습니다: ${e.message}',
      400 => '지원하지 않는 요청입니다: ${e.message}',
      401 => e is CloudAuthException ? e.message : '허브 비밀키가 올바르지 않습니다.',
      429 => e.message,
      501 => e.message,
      404 => '기기를 찾을 수 없습니다.',
      503 => '연동이 설정되지 않았습니다: ${e.message}',
      0 => e.message,
      _ => '명령 실패 (${e.statusCode}): ${e.message}',
    };
    messenger?.showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: Duration(seconds: e.statusCode == 403 ? 6 : 4),
      ),
    );
    return false;
  }
}

/// Card shell used by every capability widget.
class CapCard extends StatelessWidget {
  const CapCard({super.key, required this.title, required this.child, this.icon, this.trailing});
  final String title;
  final Widget child;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
                Expanded(child: Text(title, style: t.titleMedium)),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.valueColor});
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        Text(
          value,
          style: TextStyle(fontWeight: FontWeight.w600, color: valueColor),
        ),
      ],
    ),
  );
}

/// Wrap of choice chips (used for any "one of a list" setting).
class OptionChips extends StatelessWidget {
  const OptionChips({super.key, required this.options, required this.selected, required this.onSelected, this.label});
  final List<String> options;
  final String? selected;
  final ValueChanged<String>? onSelected;
  final String Function(String)? label;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final o in options)
        ChoiceChip(
          label: Text(label?.call(o) ?? o),
          selected: o == selected,
          onSelected: onSelected == null ? null : (_) => onSelected!(o),
        ),
    ],
  );
}
