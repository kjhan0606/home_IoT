import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../backend/device_backend.dart';
import '../camera/camera_models.dart';
import '../state/hub_state.dart';

/// Add a camera: pick an auto-discovered ONVIF camera, or type an address
/// (ONVIF host, RTSP URL, or an MJPEG/JPEG URL) with user name and password.
/// The password is stored in secure storage (direct mode) or on the hub (hub mode).
class AddCameraScreen extends StatefulWidget {
  const AddCameraScreen({super.key});

  @override
  State<AddCameraScreen> createState() => _AddCameraScreenState();
}

enum _Kind { discovered, manual }

class _AddCameraScreenState extends State<AddCameraScreen> {
  _Kind _kind = _Kind.discovered;
  String _manualProtocol = CameraProtocol.rtsp;
  final _name = TextEditingController();
  final _address = TextEditingController(); // ONVIF host
  final _url = TextEditingController(); // rtsp:// or http://
  final _user = TextEditingController();
  final _pass = TextEditingController();
  List<DiscoveredCamera>? _found;
  bool _searching = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  DiscoveredCamera? _picked;

  CameraBackend get _backend => context.read<HubState>().backend! as CameraBackend;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    for (final c in [_name, _address, _url, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final f = await _backend.discoverCameras();
      if (mounted) setState(() => _found = f);
    } on BackendException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _submit(NewCamera cam) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final nav = Navigator.of(context);
    final hub = context.read<HubState>();
    try {
      await _backend.addCamera(cam);
      await hub.reload();
      if (mounted) nav.pop(true);
    } on BackendException catch (e) {
      if (mounted) {
        setState(() {
          _error = switch (e.statusCode) {
            403 => '카메라가 사용자 이름/비밀번호를 거부했습니다. 다시 확인하세요.',
            _ => e.message,
          };
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _add() {
    final name = _name.text.trim().isEmpty ? (_picked?.label ?? '카메라') : _name.text.trim();
    if (_kind == _Kind.discovered) {
      final addr = _picked?.onvifUrl ?? _address.text.trim();
      if (addr.isEmpty) {
        setState(() => _error = '카메라를 선택하거나 주소를 입력하세요.');
        return;
      }
      _submit(NewCamera(protocol: CameraProtocol.onvif, name: name, address: addr, username: _user.text.trim(), password: _pass.text));
    } else {
      if (_url.text.trim().isEmpty) {
        setState(() => _error = '카메라 주소를 입력하세요.');
        return;
      }
      _submit(NewCamera(protocol: _manualProtocol, name: name, url: _url.text.trim(), username: _user.text.trim(), password: _pass.text));
    }
  }

  @override
  Widget build(BuildContext context) {
    final backend = context.read<HubState>().backend;
    final canDemo = backend is CameraBackend && (backend as CameraBackend).canAddDemoCamera;
    return Scaffold(
      appBar: AppBar(title: const Text('카메라 추가')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<_Kind>(
            key: const Key('camera-kind'),
            segments: const [
              ButtonSegment(value: _Kind.discovered, icon: Icon(Icons.radar), label: Text('자동 검색')),
              ButtonSegment(value: _Kind.manual, icon: Icon(Icons.edit_outlined), label: Text('주소 입력')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() {
              _kind = s.first;
              _error = null;
            }),
          ),
          const SizedBox(height: 12),
          if (_kind == _Kind.discovered) ...[
            Row(
              children: [
                Expanded(child: Text('같은 Wi-Fi의 ONVIF 카메라', style: Theme.of(context).textTheme.titleSmall)),
                TextButton.icon(
                  key: const Key('camera-search'),
                  onPressed: _searching ? null : _search,
                  icon: _searching
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh),
                  label: const Text('다시 검색'),
                ),
              ],
            ),
            if (_found != null && _found!.isEmpty && !_searching)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('찾은 카메라가 없습니다. 카메라에서 ONVIF 를 켰는지 확인하거나 IP 주소를 직접 입력하세요.'),
              ),
            RadioGroup<DiscoveredCamera>(
              groupValue: _picked,
              onChanged: (v) => setState(() {
                _picked = v;
                _address.text = v?.host ?? '';
                if (_name.text.isEmpty) _name.text = v?.label ?? '';
              }),
              child: Column(
                children: [
                  for (final c in _found ?? const <DiscoveredCamera>[])
                    RadioListTile<DiscoveredCamera>(
                      key: Key('found-${c.host}'),
                      value: c,
                      title: Text(c.label),
                      subtitle: Text(c.added ? '${c.host} · 이미 추가됨' : c.host),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('camera-address'),
              controller: _address,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: '카메라 IP 주소 (예: 192.168.0.50)', border: OutlineInputBorder()),
              onChanged: (_) => _picked = null,
            ),
          ] else ...[
            DropdownButtonFormField<String>(
              key: const Key('camera-protocol'),
              isExpanded: true,
              initialValue: _manualProtocol,
              decoration: const InputDecoration(labelText: '방식', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: CameraProtocol.rtsp, child: Text('RTSP 주소 (rtsp://...)')),
                DropdownMenuItem(value: CameraProtocol.http, child: Text('MJPEG / JPEG 주소 (http://...)')),
              ],
              onChanged: (v) => setState(() => _manualProtocol = v ?? CameraProtocol.rtsp),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('camera-url'),
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: '카메라 주소',
                hintText: _manualProtocol == CameraProtocol.rtsp ? 'rtsp://192.168.0.50:554/stream1' : 'http://192.168.0.50/video.mjpg',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            key: const Key('camera-name'),
            controller: _name,
            decoration: const InputDecoration(labelText: '이름 (예: 현관)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('camera-user'),
            controller: _user,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '카메라 사용자 이름', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('camera-pass'),
            controller: _pass,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '카메라 비밀번호',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(onPressed: () => setState(() => _obscure = !_obscure), icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off)),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.read<HubState>().backend?.kind == BackendKind.hub
                ? '비밀번호는 허브에만 저장되며 폰에는 저장되지 않습니다.'
                : '비밀번호는 이 폰의 보안 저장소(Keychain/Keystore)에만 저장됩니다.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, key: const Key('camera-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('camera-add'),
            onPressed: _busy ? null : _add,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_a_photo_outlined),
            label: const Text('카메라 추가'),
          ),
          const SizedBox(height: 16),
          const _Cautions(),
          if (canDemo) ...[
            const Divider(height: 32),
            Text('체험용', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text('실제 카메라가 없어도 화면을 써볼 수 있는 예시 카메라입니다 (그림 파일).'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  key: const Key('add-demo-living'),
                  onPressed: _busy ? null : () => _submit(const NewCamera(protocol: CameraProtocol.demo, name: '거실 카메라 (예시)', url: 'living')),
                  child: const Text('예시: 거실 (회전 가능)'),
                ),
                OutlinedButton(
                  key: const Key('add-demo-door'),
                  onPressed: _busy ? null : () => _submit(const NewCamera(protocol: CameraProtocol.demo, name: '현관 카메라 (예시)', url: 'door')),
                  child: const Text('예시: 현관'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Cautions extends StatelessWidget {
  const _Cautions();

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: const Padding(
      padding: EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('안전을 위해', style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          Text('• 카메라의 기본 비밀번호(admin/1234 등)는 꼭 바꾸세요.'),
          Text('• 카메라 포트(554, 80 등)를 공유기에서 인터넷으로 열지 마세요.'),
          Text('• 집 밖에서 보는 기능은 아직 없습니다(유료 중계 기능으로 준비 중).'),
          Text('• 가족 외 사람이 찍힐 수 있는 곳은 개인정보 보호법(PIPA)을 확인하세요.'),
        ],
      ),
    ),
  );
}
