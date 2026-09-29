import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../backend/device_backend.dart';
import '../camera/camera_models.dart';
import '../camera/mjpeg.dart';
import '../models/capability_spec.dart';
import '../models/device.dart';
import '../models/hub_config.dart';
import '../models/vacuum_map.dart';

/// Error from the hub: HTTP status + the hub's `detail` message.
class HubApiException extends BackendException {
  const HubApiException(super.statusCode, super.message); // 0 = network error / unreachable
}

/// Event pushed on `/ws` (kept under its old name for the hub code and tests).
typedef HubEvent = BackendEvent;

/// The **hub** implementation of [DeviceBackend], plus the hub-only extras
/// (health, integrations, Roborock linking). Screens that only need devices
/// depend on [DeviceBackend]; hub-specific settings screens use this type.
abstract class HubApi implements DeviceBackend {
  HubConfig get config;
  Future<Map<String, dynamic>> health();
  Future<Map<String, dynamic>> integrations();
  Future<Map<String, dynamic>> roborockStatus();
  Future<Map<String, dynamic>> roborockRequestCode(String email);
  Future<Map<String, dynamic>> roborockLogin(String email, {String? code, String? password});
  Future<Map<String, dynamic>> roborockUnlink();
}

class HttpHubApi implements HubApi, CameraBackend {
  HttpHubApi(this.config, {http.Client? client}) : _client = client ?? http.Client();

  @override
  final HubConfig config;
  final http.Client _client;
  String? _hubName;
  static const _timeout = Duration(seconds: 15);
  static const _scanTimeout = Duration(seconds: 120);

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (config.token != null) 'X-HomeHub-Token': config.token!,
  };

  Uri _u(String path, [Map<String, String>? q]) => config.baseUri.replace(path: path, queryParameters: q);

  /// Device ids contain ':' (e.g. "samsung_local:aa:bb"); keep them readable
  /// but escape anything else (the hub route is `{id:path}`).
  static String _id(String id) => Uri.encodeComponent(id).replaceAll('%3A', ':');

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = _timeout,
  }) async {
    final req = http.Request(method, _u(path, query))..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(timeout));
    } on TimeoutException {
      throw const HubApiException(0, '허브 응답 시간이 초과되었습니다.');
    } catch (e) {
      throw HubApiException(0, '허브에 연결할 수 없습니다: $e');
    }
    final text = utf8.decode(res.bodyBytes);
    dynamic data;
    try {
      data = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      data = text;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final detail = data is Map && data['detail'] != null ? data['detail'].toString() : text;
      throw HubApiException(res.statusCode, detail);
    }
    return data;
  }

  @override
  BackendKind get kind => BackendKind.hub;
  @override
  String get title => _hubName ?? '허브';
  @override
  String? get subtitle => config.label;
  @override
  bool get hasEventStream => true;
  @override
  Duration? get pollInterval => null;
  @override
  Map<String, String> get warnings => const {};

  Map<String, dynamic> _map(dynamic d) => Map<String, dynamic>.from((d as Map?) ?? const {});
  List<Device> _devs(dynamic d) =>
      ((_map(d)['devices'] as List?) ?? const []).map((e) => Device.fromJson(Map<String, dynamic>.from(e))).toList();

  @override
  Future<Map<String, dynamic>> health() async {
    final h = _map(await _send('GET', '/health', timeout: const Duration(seconds: 5)));
    _hubName = h['name']?.toString() ?? _hubName;
    return h;
  }

  @override
  Future<Map<String, CapabilitySpec>> capabilities() async =>
      CapabilitySpec.parseCatalog(_map(await _send('GET', '/capabilities')));

  @override
  Future<List<Device>> devices() async => _devs(await _send('GET', '/devices'));

  @override
  Future<Device> device(String id) async => Device.fromJson(_map(await _send('GET', '/devices/${_id(id)}')));

  @override
  Future<Device> refresh(String id) async => Device.fromJson(_map(await _send('POST', '/devices/${_id(id)}/refresh')));

  @override
  Future<List<Device>> sync() => devices();

  @override
  Future<List<Device>> scan({bool lan = true, bool cloud = true}) async =>
      _devs(await _send('POST', '/scan', query: {'lan': '$lan', 'cloud': '$cloud'}, timeout: _scanTimeout));

  @override
  Future<Map<String, dynamic>> command(
    String id,
    String capability,
    String action, [
    Map<String, dynamic> params = const {},
  ]) async => _map(
    await _send(
      'POST',
      '/devices/${_id(id)}/commands',
      body: {'capability': capability, 'action': action, 'params': params},
    ),
  );

  @override
  Future<VacuumMap> vacuumMap(String id) async =>
      VacuumMap.fromJson(_map(await _send('GET', '/devices/${_id(id)}/map', timeout: const Duration(seconds: 45))));

  @override
  Future<Map<String, dynamic>> integrations() async => _map(await _send('GET', '/integrations'));

  @override
  Future<Map<String, dynamic>> roborockStatus() async => _map(await _send('GET', '/integrations/roborock'));

  @override
  Future<Map<String, dynamic>> roborockRequestCode(String email) async =>
      _map(await _send('POST', '/integrations/roborock/request-code', body: {'email': email}));

  @override
  Future<Map<String, dynamic>> roborockLogin(String email, {String? code, String? password}) async => _map(
    await _send(
      'POST',
      '/integrations/roborock/login',
      body: {'email': email, 'code': ?code, 'password': ?password},
      timeout: const Duration(seconds: 60),
    ),
  );

  @override
  Future<Map<String, dynamic>> roborockUnlink() async =>
      _map(await _send('POST', '/integrations/roborock/unlink', timeout: const Duration(seconds: 60)));

  // ------------------------------------------------------------- cameras ----
  // Hub mode: the hub holds the camera password; the phone only ever talks to the hub.
  @override
  bool get canAddDemoCamera => false;

  @override
  Future<CameraFeed> cameraFeed(String deviceId) async => _HubCameraFeed(this, deviceId);

  @override
  Future<List<DiscoveredCamera>> discoverCameras() async {
    final r = _map(await _send('GET', '/cameras/discover', timeout: const Duration(seconds: 20)));
    return [for (final c in (r['cameras'] as List?) ?? const []) DiscoveredCamera.fromJson(Map<String, dynamic>.from(c as Map))];
  }

  @override
  Future<Device> addCamera(NewCamera c) async {
    final body = {
      'protocol': c.protocol,
      'name': c.name,
      if (c.address.isNotEmpty) 'address': c.address,
      if (c.url.isNotEmpty) 'url': c.url,
      'username': c.username,
      'password': c.password,
      if (c.room != null && c.room!.isNotEmpty) 'room': c.room,
    };
    final r = _map(await _send('POST', '/cameras', body: body, timeout: const Duration(seconds: 45)));
    return Device.fromJson(_map(r['device']));
  }

  @override
  Future<void> removeCamera(String deviceId) async {
    await _send('DELETE', '/cameras/${_id(deviceId)}');
  }

  Future<Uint8List> _cameraSnapshot(String id) async {
    final req = http.Request('GET', _u('/devices/${_id(id)}/snapshot.jpg'))..headers.addAll(_headers);
    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 15)));
    } catch (e) {
      throw HubApiException(0, '허브에 연결할 수 없습니다: $e');
    }
    if (res.statusCode != 200) {
      var detail = res.body;
      try {
        detail = (jsonDecode(res.body) as Map)['detail'].toString();
      } catch (_) {}
      throw HubApiException(res.statusCode, detail);
    }
    return res.bodyBytes;
  }

  Stream<Uint8List> _cameraMjpeg(String id) {
    late StreamController<Uint8List> ctl;
    StreamSubscription<Uint8List>? sub;
    ctl = StreamController<Uint8List>(
      onListen: () async {
        try {
          final req = http.Request('GET', _u('/devices/${_id(id)}/stream.mjpeg'))..headers.addAll(_headers);
          final res = await _client.send(req).timeout(const Duration(seconds: 15));
          if (res.statusCode != 200) {
            final body = await res.stream.bytesToString();
            var detail = body;
            try {
              detail = (jsonDecode(body) as Map)['detail'].toString();
            } catch (_) {}
            throw HubApiException(res.statusCode, detail);
          }
          sub = jpegFrames(res.stream).listen(ctl.add, onError: ctl.addError, onDone: ctl.close);
        } catch (e) {
          ctl.addError(e is BackendException ? e : HubApiException(0, '허브에 연결할 수 없습니다: $e'));
          await ctl.close();
        }
      },
      onCancel: () => sub?.cancel(),
    );
    return ctl.stream;
  }

  @override
  Stream<HubEvent> events() {
    final ch = WebSocketChannel.connect(config.wsUri);
    return ch.stream
        .map((raw) {
          final j = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
          if (j is! Map) return null;
          final m = Map<String, dynamic>.from(j);
          return HubEvent((m['type'] ?? '').toString(), m);
        })
        .where((e) => e != null)
        .cast<HubEvent>()
        .handleError((Object _) {}); // socket errors just end the stream
  }

  @override
  void close() => _client.close();
}

/// Camera pictures relayed by the hub. No RTSP URL is exposed on purpose: the
/// hub owns the camera password, and its MJPEG relay works on every platform.
class _HubCameraFeed implements CameraFeed {
  _HubCameraFeed(this._api, this._id);
  final HttpHubApi _api;
  final String _id;

  @override
  Future<Uint8List> snapshot() => _api._cameraSnapshot(_id);
  @override
  Stream<Uint8List>? mjpeg() => _api._cameraMjpeg(_id);
  @override
  String? get rtspUrl => null;
  @override
  bool get hasSnapshot => true;
}
