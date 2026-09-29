import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../backend/device_backend.dart';
import '../camera/camera_models.dart';
import '../l10n/ko.dart';
import '../state/hub_state.dart';
import '../widgets/capabilities/camera.dart';

/// Full camera page: live picture, snapshot refresh, PTZ (only if the device has
/// the `ptz` capability) and remove. Built from canonical capabilities only.
class CameraScreen extends StatelessWidget {
  const CameraScreen({super.key, required this.deviceId});
  final String deviceId;

  Future<void> _remove(BuildContext context) async {
    final hub = context.read<HubState>();
    final b = hub.backend;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('카메라 삭제'),
        content: const Text('이 카메라를 앱(또는 허브)에서 지웁니다. 저장된 카메라 비밀번호도 함께 삭제됩니다. 카메라 자체에는 영향이 없습니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(key: const Key('confirm-remove-camera'), onPressed: () => Navigator.pop(c, true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true || b is! CameraBackend) return;
    try {
      await (b as CameraBackend).removeCamera(deviceId);
      await hub.reload();
      nav.pop();
    } on BackendException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('삭제 실패: ${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<HubState>();
    final d = hub.device(deviceId);
    if (d == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('카메라를 찾을 수 없습니다.')));
    }
    final stream = d.cap('videoStream');
    final ptz = d.cap('ptz');
    final canRemove = hub.backend is CameraBackend && !d.isExample;
    return Scaffold(
      appBar: AppBar(
        title: Text(d.name),
        actions: [
          if (d.isExample)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Chip(label: Text(Ko.example), visualDensity: VisualDensity.compact),
            ),
          if (canRemove)
            PopupMenuButton<String>(
              key: const Key('camera-menu'),
              onSelected: (v) => v == 'remove' ? _remove(context) : null,
              itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('카메라 삭제'))],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        children: [
          if (stream != null) CameraCard(device: d, inst: stream, compact: false),
          if (ptz != null) PtzCard(device: d, inst: ptz),
          const _PrivacyNote(),
        ],
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Text(
      '이 화면은 집 안 Wi-Fi 안에서만 보입니다. 카메라 포트를 인터넷에 열지 마세요. '
      '다른 사람이 찍히는 영상은 개인정보 보호법(PIPA)의 대상이 될 수 있습니다.',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}
