import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../../camera/camera_models.dart';
import '../../camera/camera_store.dart';
import '../../camera/camera_urls.dart';
import '../../camera/http_auth.dart';
import '../../camera/mjpeg.dart';
import '../../camera/net_stub.dart' if (dart.library.io) '../../camera/net_io.dart' as net;
import '../../camera/onvif_client.dart';
import '../../models/device.dart';
import '../device_backend.dart';
import 'cloud_provider.dart';

/// IP cameras in **direct mode** (the phone talks to the camera itself on the
/// LAN). Port of `hub/homehub/adapters/camera.py` behind the same [CloudProvider]
/// contract, so the direct backend treats cameras like any other provider and the UI
/// sees the same brand-neutral `videoStream` / `ptz` devices as in hub mode.
///
/// Credentials stay in [CameraStore] (secure storage) and in memory while viewing.
class DirectCameraProvider implements CloudProvider {
  DirectCameraProvider(
    this.store, {
    http.Client? client,
    Future<bool> Function(String host, int port)? probe,
    Future<List<DiscoveredCamera>> Function()? discover,
    Future<Uint8List> Function(String asset)? loadAsset,
    Random? random,
  }) : _client = client ?? http.Client(),
       _probe = probe ?? ((h, p) => net.tcpProbe(h, p)),
       _discover = discover ?? net.wsDiscoverPlatform,
       _loadAsset = loadAsset ?? _bundleAsset,
       _rng = random ?? Random.secure();

  final CameraStore store;
  final http.Client _client;
  final Future<bool> Function(String host, int port) _probe;
  final Future<List<DiscoveredCamera>> Function() _discover;
  final Future<Uint8List> Function(String asset) _loadAsset;
  final Random _rng;
  final Map<String, bool> _reachable = {};
  final Map<String, ({int col, int row})> _demoPtz = {};
  final Map<String, Timer> _stopTimers = {};

  @override
  String get id => 'camera';
  @override
  String get name => 'IP 카메라';

  static Future<Uint8List> _bundleAsset(String a) async => (await rootBundle.load(a)).buffer.asUint8List();

  // -------------------------------------------------------------- listing ----
  @override
  Future<List<Device>> listDevices() async {
    final cams = await store.list();
    final up = await Future.wait<bool>(cams.map((c) async {
      if (c.protocol == CameraProtocol.demo) return true;
      final target = _hostPort(c);
      return target == null ? false : _probe(target.$1, target.$2);
    }));
    return [
      for (var i = 0; i < cams.length; i++) cams[i].toDevice(reachable: _reachable[cams[i].id] = up[i]),
    ];
  }

  (String, int)? _hostPort(CameraConfig c) {
    for (final u in [c.rtspUrl, c.snapshotUrl, c.mjpegUrl, c.onvifUrl]) {
      if (u != null) {
        final uri = Uri.tryParse(u);
        if (uri != null && uri.host.isNotEmpty) return (uri.host, defaultPort(u));
      }
    }
    return c.host == null ? null : (c.host!, 554);
  }

  @override
  Future<Device> refresh(Device device) async {
    final c = await store.get(device.id);
    if (c == null) throw const BackendException(404, '카메라를 찾을 수 없습니다.');
    return c.toDevice(reachable: _reachable[c.id] ?? device.reachable);
  }

  // --------------------------------------------------------------- adding ----
  Future<List<DiscoveredCamera>> discover() async {
    final added = {for (final c in await store.list()) c.host};
    final found = await _discover();
    return [
      for (final f in found)
        DiscoveredCamera(host: f.host, onvifUrl: f.onvifUrl, name: f.name, hardware: f.hardware, added: added.contains(f.host)),
    ];
  }

  String _newId() => 'camera:${List.generate(4, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Device> add(NewCamera n) async {
    final name = n.name.trim().isEmpty ? '카메라' : n.name.trim();
    final room = (n.room ?? '').trim();
    final base = CameraConfig(
      id: _newId(),
      name: name,
      protocol: n.protocol,
      username: n.username.trim(),
      password: n.password,
      room: room.isEmpty ? null : room,
    );
    final CameraConfig cfg = switch (n.protocol) {
      CameraProtocol.onvif => await _configureOnvif(base, n.address),
      CameraProtocol.rtsp => await _configureRtsp(base, n.url),
      CameraProtocol.http => await _configureHttp(base, n.url),
      CameraProtocol.demo => _configureDemo(base, n.url),
      _ => throw const BackendException(400, '지원하지 않는 카메라 방식입니다.'),
    };
    await store.put(cfg);
    return cfg.toDevice(reachable: _reachable[cfg.id] = true);
  }

  Future<CameraConfig> _configureOnvif(CameraConfig b, String address) async {
    if (address.trim().isEmpty) throw const BackendException(400, '카메라 주소를 입력하세요.');
    final url = OnvifClient.normalizeDeviceUrl(address);
    final c = OnvifClient(url, username: b.username, password: b.password, client: _client);
    final info = await c.deviceInformation();
    await c.discoverServices();
    final profiles = await c.profiles();
    final best = profiles.firstWhere((p) => (p['codec']?.toString().toUpperCase()) == 'H264', orElse: () => profiles.first);
    final token = best['token'] as String;
    final rtsp = splitCredentials(await c.streamUri(token)).url;
    final snap = await c.snapshotUri(token);
    var pt = false, zoom = false;
    var presets = <Map<String, dynamic>>[];
    if (c.ptzUrl != null && profiles.any((p) => p['ptz'] == true)) {
      pt = zoom = true;
      try {
        presets = await c.ptzPresets(token);
      } on BackendException {
        presets = [];
      }
    }
    return CameraConfig(
      id: b.id,
      name: b.name,
      protocol: CameraProtocol.onvif,
      username: b.username,
      password: b.password,
      room: b.room,
      host: Uri.parse(url).host,
      onvifUrl: url,
      rtspUrl: rtsp,
      snapshotUrl: snap == null ? null : splitCredentials(snap).url,
      vendor: info['Manufacturer'],
      model: info['Model'],
      profiles: [for (final p in profiles) {for (final k in const ['token', 'name', 'codec', 'width', 'height', 'ptz']) k: p[k]}],
      selectedProfile: token,
      ptzPanTilt: pt,
      ptzZoom: zoom,
      presets: presets,
    );
  }

  Future<CameraConfig> _configureRtsp(CameraConfig b, String input) async {
    final s = input.trim();
    if (!(s.toLowerCase().startsWith('rtsp://') || s.toLowerCase().startsWith('rtsps://'))) {
      throw const BackendException(400, 'RTSP 주소는 rtsp:// 로 시작해야 합니다.');
    }
    final sp = _split(s);
    final user = b.username.isEmpty ? (sp.user ?? '') : b.username;
    final pw = b.username.isEmpty ? (sp.password ?? '') : b.password;
    final host = Uri.parse(sp.url).host;
    if (!await _probe(host, defaultPort(sp.url))) {
      throw BackendException(502, '$host:${defaultPort(sp.url)} 에 연결할 수 없습니다.');
    }
    return CameraConfig(
      id: b.id, name: b.name, protocol: CameraProtocol.rtsp, username: user, password: pw, room: b.room,
      host: host, rtspUrl: sp.url,
    );
  }

  Future<CameraConfig> _configureHttp(CameraConfig b, String input) async {
    final s = input.trim();
    if (!(s.toLowerCase().startsWith('http://') || s.toLowerCase().startsWith('https://'))) {
      throw const BackendException(400, '주소는 http:// 또는 https:// 로 시작해야 합니다.');
    }
    final sp = _split(s);
    final user = b.username.isEmpty ? (sp.user ?? '') : b.username;
    final pw = b.username.isEmpty ? (sp.password ?? '') : b.password;
    final auth = AuthHttp(_client, username: user, password: pw);
    final res = await _get(auth, sp.url);
    final ctype = (res.headers['content-type'] ?? '').toLowerCase();
    await res.stream.drain<void>();
    final host = Uri.parse(sp.url).host;
    if (ctype.contains('multipart')) {
      return CameraConfig(id: b.id, name: b.name, protocol: CameraProtocol.http, username: user, password: pw, room: b.room, host: host, mjpegUrl: sp.url);
    }
    if (ctype.contains('image/jpeg') || ctype.contains('image/jpg')) {
      return CameraConfig(id: b.id, name: b.name, protocol: CameraProtocol.http, username: user, password: pw, room: b.room, host: host, snapshotUrl: sp.url);
    }
    throw BackendException(502, 'MJPEG 스트림이나 JPEG 스냅샷 주소가 아닙니다 (${ctype.isEmpty ? '알 수 없음' : ctype}).');
  }

  CameraConfig _configureDemo(CameraConfig b, String scene) {
    final s = scene == 'door' ? 'door' : 'living';
    return CameraConfig(
      id: b.id, name: b.name, protocol: CameraProtocol.demo, room: b.room ?? (s == 'door' ? '현관' : '거실'), demoScene: s,
      ptzPanTilt: s == 'living', ptzZoom: false,
      presets: s == 'living'
          ? const [
              {'token': '1', 'name': '소파'},
              {'token': '2', 'name': '창가'},
            ]
          : const [],
      profiles: const [
        {'token': 'main', 'name': 'Main', 'width': 640, 'height': 360, 'codec': 'JPEG'},
      ],
      selectedProfile: 'main',
    );
  }

  ({String url, String? user, String? password}) _split(String s) {
    try {
      return splitCredentials(s);
    } on FormatException {
      throw const BackendException(400, '주소가 올바르지 않습니다.');
    }
  }

  Future<void> remove(String id) async {
    _stopTimers.remove(id)?.cancel();
    if (!await store.remove(id)) throw const BackendException(404, '카메라를 찾을 수 없습니다.');
    _reachable.remove(id);
  }

  // ---------------------------------------------------------------- media ----
  Future<http.StreamedResponse> _get(AuthHttp auth, String url) async {
    try {
      final res = await auth.open('GET', Uri.parse(url));
      if (res.statusCode == 401) {
        await res.stream.drain<void>();
        throw const BackendException(403, '카메라가 사용자 이름 또는 비밀번호를 거부했습니다.');
      }
      if (res.statusCode >= 400) {
        await res.stream.drain<void>();
        throw BackendException(502, '카메라가 HTTP ${res.statusCode}로 응답했습니다.');
      }
      return res;
    } on BackendException {
      rethrow;
    } on TimeoutException {
      throw const BackendException(502, '카메라가 응답하지 않습니다.');
    } catch (_) {
      throw const BackendException(502, '카메라에 연결할 수 없습니다.');
    }
  }

  Future<CameraFeed> feed(String deviceId) async {
    final c = await store.get(deviceId);
    if (c == null) throw const BackendException(404, '카메라를 찾을 수 없습니다.');
    return _Feed(this, c);
  }

  Future<Uint8List> _demoFrame(CameraConfig c) async {
    if (c.demoScene == 'door') return _loadAsset('assets/demo/demo_door.jpg');
    final p = _demoPtz[c.id] ?? (col: 1, row: 1);
    return _loadAsset('assets/demo/demo_living_${p.col}_${p.row}.jpg');
  }

  Future<Uint8List> _snapshot(CameraConfig c) async {
    if (c.demoScene != null) return _demoFrame(c);
    final auth = AuthHttp(_client, username: c.username, password: c.password);
    if (c.snapshotUrl != null) {
      final res = await http.Response.fromStream(await _get(auth, c.snapshotUrl!));
      final b = res.bodyBytes;
      if (b.length < 2 || b[0] != 0xFF || b[1] != 0xD8) throw const BackendException(502, '카메라 스냅샷이 JPEG 이미지가 아닙니다.');
      return b;
    }
    if (c.mjpegUrl != null) {
      final res = await _get(auth, c.mjpegUrl!);
      try {
        return await jpegFrames(res.stream).first.timeout(const Duration(seconds: 8));
      } on StateError {
        throw const BackendException(502, '카메라 스트림에서 화면을 받지 못했습니다.');
      } on TimeoutException {
        throw const BackendException(502, '카메라가 화면을 보내지 않습니다.');
      }
    }
    throw const BackendException(501, '이 카메라는 스냅샷 주소가 없습니다. 실시간 보기를 이용하세요.');
  }

  Stream<Uint8List>? _mjpeg(CameraConfig c) {
    if (c.demoScene != null) {
      return Stream.periodic(const Duration(milliseconds: 400)).asyncMap((_) => _demoFrame(c));
    }
    if (c.mjpegUrl == null) return null;
    late StreamController<Uint8List> ctl;
    StreamSubscription<Uint8List>? sub;
    ctl = StreamController<Uint8List>(
      onListen: () async {
        try {
          final res = await _get(AuthHttp(_client, username: c.username, password: c.password), c.mjpegUrl!);
          sub = jpegFrames(res.stream).listen(ctl.add, onError: ctl.addError, onDone: ctl.close);
        } catch (e) {
          ctl.addError(e);
          await ctl.close();
        }
      },
      onCancel: () => sub?.cancel(),
    );
    return ctl.stream;
  }

  // ------------------------------------------------------------- commands ----
  @override
  Future<Map<String, dynamic>> execute(Device device, String capability, String action, Map<String, dynamic> params) async {
    validateAction(capability, action);
    final c = await store.get(device.id);
    if (c == null) throw const BackendException(404, '카메라를 찾을 수 없습니다.');
    if (c.demoScene != null) return _demoCommand(c, capability, action, params);
    if (c.protocol != CameraProtocol.onvif) {
      throw const BackendException(400, 'ONVIF 로 추가하지 않은 카메라는 PTZ/프로필 선택을 지원하지 않습니다.');
    }
    final client = OnvifClient(c.onvifUrl!, username: c.username, password: c.password, client: _client);
    await client.discoverServices();
    final token = c.selectedProfile!;
    if (capability == 'videoStream') {
      final want = params['profile'];
      if (!c.profiles.any((p) => p['token'] == want)) throw const BackendException(400, '알 수 없는 프로필입니다.');
      final rtsp = splitCredentials(await client.streamUri(want as String)).url;
      final snap = await client.snapshotUri(want);
      await store.put(c.copyWith(selectedProfile: want, rtspUrl: rtsp, snapshotUrl: snap == null ? null : splitCredentials(snap).url));
      return {'ok': true, 'profile': want};
    }
    switch (action) {
      case 'move':
        final pan = _axis(params, 'pan'), tilt = _axis(params, 'tilt'), zoom = _axis(params, 'zoom');
        final ms = _ms(params);
        if (pan == 0 && tilt == 0 && zoom == 0) throw const BackendException(400, 'pan, tilt, zoom 중 하나는 0이 아니어야 합니다.');
        await client.ptzMove(token, pan, tilt, zoom, timeoutSeconds: ms / 1000);
        // Many cameras ignore the ContinuousMove timeout: stop explicitly.
        _stopTimers.remove(c.id)?.cancel();
        _stopTimers[c.id] = Timer(Duration(milliseconds: ms + 200), () async {
          try {
            await client.ptzStop(token);
          } catch (_) {}
        });
        return {'ok': true};
      case 'stop':
        _stopTimers.remove(c.id)?.cancel();
        await client.ptzStop(token);
        return {'ok': true};
      case 'gotoPreset':
        if (!c.presets.any((p) => p['token'] == params['preset'])) throw const BackendException(400, '알 수 없는 프리셋입니다.');
        await client.ptzGotoPreset(token, params['preset'] as String);
        return {'ok': true};
    }
    throw BackendException(400, '지원하지 않는 명령입니다: $capability.$action');
  }

  double _axis(Map<String, dynamic> p, String k) {
    final v = p[k] ?? 0;
    if (v is! num || v is bool || v < -1 || v > 1) throw BackendException(400, "'$k' 는 -1..1 사이 숫자여야 합니다.");
    return v.toDouble();
  }

  int _ms(Map<String, dynamic> p) {
    final v = p['durationMs'] ?? 500;
    if (v is! num || v < 100 || v > 5000) throw const BackendException(400, "'durationMs' 는 100..5000 이어야 합니다.");
    return v.toInt();
  }

  Map<String, dynamic> _demoCommand(CameraConfig c, String capability, String action, Map<String, dynamic> p) {
    if (capability != 'ptz') throw const BackendException(400, '지원하지 않는 명령입니다.');
    final pos = _demoPtz[c.id] ?? (col: 1, row: 1);
    var col = pos.col, row = pos.row;
    if (action == 'move') {
      final pan = _axis(p, 'pan'), tilt = _axis(p, 'tilt');
      if (pan > 0.3) col = min(2, col + 1);
      if (pan < -0.3) col = max(0, col - 1);
      if (tilt > 0.3) row = max(0, row - 1);
      if (tilt < -0.3) row = min(2, row + 1);
    } else if (action == 'gotoPreset') {
      final preset = p['preset'];
      if (preset == '1') {
        col = 0;
        row = 1;
      } else if (preset == '2') {
        col = 2;
        row = 1;
      } else {
        throw const BackendException(400, '알 수 없는 프리셋입니다.');
      }
    }
    _demoPtz[c.id] = (col: col, row: row);
    return {'ok': true, 'method': 'demo'};
  }

  @override
  void close() {
    for (final t in _stopTimers.values) {
      t.cancel();
    }
    _client.close();
  }
}

class _Feed implements CameraFeed {
  _Feed(this._p, this._c);
  final DirectCameraProvider _p;
  final CameraConfig _c;

  @override
  Future<Uint8List> snapshot() => _p._snapshot(_c);
  @override
  Stream<Uint8List>? mjpeg() => _p._mjpeg(_c);
  @override
  String? get rtspUrl => _c.rtspUrl == null ? null : withCredentials(_c.rtspUrl!, _c.username, _c.password);
  @override
  bool get hasSnapshot => _c.snapshotAvailable;
}

