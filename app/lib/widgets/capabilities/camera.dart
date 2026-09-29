import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../backend/device_backend.dart';
import '../../camera/camera_models.dart';
import '../../camera/camera_player.dart';
import '../../l10n/ko.dart';
import '../../models/device.dart';
import '../../screens/camera_screen.dart';
import '../../state/hub_state.dart';
import '../command.dart';

/// How a camera picture is delivered. Chosen from what the feed offers, never
/// from the camera's brand.
enum LiveMode { rtsp, mjpeg, snapshot }

String liveModeLabel(LiveMode m) => switch (m) {
  LiveMode.rtsp => '실시간',
  LiveMode.mjpeg => '영상',
  LiveMode.snapshot => '사진',
};

/// uiHint "camera-view": live picture + snapshot refresh + profile picker.
class CameraCard extends StatelessWidget {
  const CameraCard({super.key, required this.device, required this.inst, this.compact = true});
  final Device device;
  final CapabilityInstance inst;

  /// In a device detail list the card offers "full screen"; on the camera screen it is the whole page.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final profiles = inst.objects('profiles');
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.videocam_outlined,
      trailing: compact
          ? IconButton(
              key: const Key('open-camera'),
              tooltip: '전체 화면',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CameraScreen(deviceId: device.id))),
              icon: const Icon(Icons.fullscreen),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LiveCameraView(deviceId: device.id, online: device.reachable),
          if (inst.supports('selectProfile') && profiles.length > 1) ...[
            const SizedBox(height: 12),
            const Text('화질/프로필'),
            const SizedBox(height: 4),
            OptionChips(
              options: [for (final p in profiles) p['token'].toString()],
              selected: inst.state['selectedProfile']?.toString(),
              label: (t) {
                final p = profiles.firstWhere((e) => e['token'].toString() == t);
                final res = (p['width'] != null && p['height'] != null) ? ' ${p['width']}×${p['height']}' : '';
                return '${p['name'] ?? t}$res';
              },
              onSelected: (t) => sendCommand(context, device.id, inst.key, 'selectProfile', params: {'profile': t}),
            ),
          ],
        ],
      ),
    );
  }
}

/// The picture itself (16:9): RTSP player -> MJPEG -> polled snapshots, with a
/// mode switch and a manual snapshot refresh.
class LiveCameraView extends StatefulWidget {
  const LiveCameraView({super.key, required this.deviceId, this.online = true, this.snapshotEvery = const Duration(seconds: 1)});
  final String deviceId;
  final bool online;
  final Duration snapshotEvery;

  @override
  State<LiveCameraView> createState() => _LiveCameraViewState();
}

class _LiveCameraViewState extends State<LiveCameraView> {
  CameraFeed? _feed;
  String? _feedError;
  LiveMode? _mode;
  List<LiveMode> _available = const [];
  Uint8List? _frame;
  String? _error;
  StreamSubscription<Uint8List>? _sub;
  Timer? _timer;
  bool _fetching = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(LiveCameraView old) {
    super.didUpdateWidget(old);
    if (old.deviceId != widget.deviceId) _open();
  }

  Future<void> _open() async {
    _stop();
    final b = context.read<HubState>().backend;
    if (b is! CameraBackend) {
      setState(() => _feedError = '이 연결 방식은 카메라를 지원하지 않습니다.');
      return;
    }
    try {
      final feed = await (b as CameraBackend).cameraFeed(widget.deviceId);
      if (!mounted) return;
      final native = !kIsWeb && CameraPlayer.rtspBuilder != null && feed.rtspUrl != null;
      final probeMjpeg = !kIsWeb; // browsers cannot stream a fetch body incrementally through package:http
      final avail = <LiveMode>[
        if (native) LiveMode.rtsp,
        if (probeMjpeg && feed.mjpeg() != null) LiveMode.mjpeg,
        if (feed.hasSnapshot) LiveMode.snapshot,
      ];
      setState(() {
        _feed = feed;
        _feedError = null;
        _available = avail;
      });
      if (avail.isEmpty) {
        setState(() => _error = '이 카메라는 앱에서 볼 수 있는 화면 주소가 없습니다.');
      } else {
        _select(avail.first);
      }
    } on BackendException catch (e) {
      if (mounted) setState(() => _feedError = e.message);
    }
  }

  void _stop() {
    _generation++;
    _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
  }

  void _select(LiveMode m) {
    _stop();
    setState(() {
      _mode = m;
      _error = null;
    });
    final gen = _generation;
    switch (m) {
      case LiveMode.rtsp:
        break; // the player widget reports errors through _fallback
      case LiveMode.mjpeg:
        final s = _feed!.mjpeg();
        if (s == null) return _fallback(m);
        _sub = s.listen(
          (f) {
            if (mounted && gen == _generation) setState(() => _frame = f);
          },
          onError: (Object e) => gen == _generation ? _fallback(m, e) : null,
        );
      case LiveMode.snapshot:
        _fetchSnapshot(gen);
        _timer = Timer.periodic(widget.snapshotEvery, (_) => _fetchSnapshot(gen));
    }
  }

  /// Playback in [failed] mode broke: try the next mode the feed offers.
  void _fallback(LiveMode failed, [Object? error]) {
    if (!mounted) return;
    final i = _available.indexOf(failed);
    if (i >= 0 && i + 1 < _available.length) {
      _select(_available[i + 1]);
    } else {
      _stop();
      setState(() => _error = error is BackendException ? error.message : (error?.toString() ?? '영상을 불러오지 못했습니다.'));
    }
  }

  Future<void> _fetchSnapshot(int gen, {bool manual = false}) async {
    if (_fetching && !manual) return;
    _fetching = true;
    try {
      final f = await _feed!.snapshot();
      if (mounted && gen == _generation) {
        setState(() {
          _frame = f;
          _error = null;
        });
      }
    } on BackendException catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e.message);
    } finally {
      _fetching = false;
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget picture;
    if (_feedError != null) {
      picture = _message(_feedError!);
    } else if (_feed == null) {
      picture = const Center(child: CircularProgressIndicator());
    } else if (_mode == LiveMode.rtsp && _error == null) {
      picture = CameraPlayer.rtspBuilder!(context, _feed!.rtspUrl!, () => _fallback(LiveMode.rtsp));
    } else if (_frame != null) {
      picture = Image.memory(_frame!, key: const Key('camera-frame'), fit: BoxFit.contain, gaplessPlayback: true);
    } else if (_error != null) {
      picture = _message(_error!);
    } else {
      picture = const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  picture,
                  if (_error != null && _frame != null)
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(8)),
                        child: Text(_error!, style: TextStyle(color: cs.onErrorContainer, fontSize: 12)),
                      ),
                    ),
                  if (!widget.online)
                    const Positioned(top: 8, left: 8, child: Chip(label: Text('오프라인'), visualDensity: VisualDensity.compact)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (_available.length > 1)
              Expanded(
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final m in _available)
                      ChoiceChip(
                        key: Key('mode-${m.name}'),
                        label: Text(liveModeLabel(m)),
                        selected: _mode == m,
                        onSelected: (_) => _select(m),
                      ),
                  ],
                ),
              )
            else
              const Spacer(),
            TextButton.icon(
              key: const Key('refresh-snapshot'),
              onPressed: _feed == null || !_feed!.hasSnapshot ? null : () => _fetchSnapshot(_generation, manual: true),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('사진 새로고침'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _message(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
    ),
  );
}

/// uiHint "ptz-pad": direction pad (hold to move), zoom, stop and presets.
class PtzCard extends StatefulWidget {
  const PtzCard({super.key, required this.device, required this.inst});
  final Device device;
  final CapabilityInstance inst;

  @override
  State<PtzCard> createState() => _PtzCardState();
}

class _PtzCardState extends State<PtzCard> {
  Timer? _hold;
  bool _errorShown = false;
  static const _tick = Duration(milliseconds: 400);

  Future<void> _send(String action, [Map<String, dynamic> params = const {}]) async {
    final b = context.read<HubState>().backend;
    if (b == null) return;
    try {
      await b.command(widget.device.id, 'ptz', action, params);
      _errorShown = false;
    } on BackendException catch (e) {
      if (!_errorShown && mounted) {
        _errorShown = true;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('카메라 이동 실패: ${e.message}')));
      }
    }
  }

  void _press(double pan, double tilt, double zoom) {
    _hold?.cancel();
    void go() => _send('move', {'pan': pan, 'tilt': tilt, 'zoom': zoom, 'durationMs': 600});
    go();
    _hold = Timer.periodic(_tick, (_) => go());
  }

  void _release() {
    if (_hold == null) return;
    _hold?.cancel();
    _hold = null;
    _send('stop');
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  Widget _btn(String key, IconData icon, String tip, double pan, double tilt, double zoom) => Listener(
    onPointerDown: (_) => _press(pan, tilt, zoom),
    onPointerUp: (_) => _release(),
    onPointerCancel: (_) => _release(),
    child: Tooltip(
      message: tip,
      child: Semantics(
        button: true,
        label: tip,
        child: Container(
          key: Key(key),
          width: 56,
          height: 56,
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(14)),
          child: Icon(icon),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final inst = widget.inst;
    final panTilt = inst.state['panTilt'] == true;
    final zoom = inst.state['zoom'] == true;
    final presets = inst.objects('presets');
    return CapCard(
      title: Ko.cap(inst.key),
      icon: Icons.open_with,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 24,
              runSpacing: 8,
              children: [
                if (panTilt)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _btn('ptz-up', Icons.keyboard_arrow_up, '위로', 0, 0.6, 0),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _btn('ptz-left', Icons.keyboard_arrow_left, '왼쪽으로', -0.6, 0, 0),
                          Container(
                            width: 56,
                            height: 56,
                            margin: const EdgeInsets.all(3),
                            child: IconButton(key: const Key('ptz-stop'), tooltip: '정지', onPressed: () => _send('stop'), icon: const Icon(Icons.stop_circle_outlined)),
                          ),
                          _btn('ptz-right', Icons.keyboard_arrow_right, '오른쪽으로', 0.6, 0, 0),
                        ],
                      ),
                      _btn('ptz-down', Icons.keyboard_arrow_down, '아래로', 0, -0.6, 0),
                    ],
                  ),
                if (zoom)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _btn('ptz-zoom-in', Icons.zoom_in, '확대', 0, 0, 0.5),
                      _btn('ptz-zoom-out', Icons.zoom_out, '축소', 0, 0, -0.5),
                    ],
                  ),
              ],
            ),
          ),
          if (inst.supports('gotoPreset') && presets.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('저장된 위치'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final p in presets)
                  ActionChip(
                    key: Key('preset-${p['token']}'),
                    label: Text('${p['name'] ?? p['token']}'),
                    onPressed: () => _send('gotoPreset', {'preset': p['token'].toString()}),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
