import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/capability_spec.dart';
import '../models/device.dart';
import '../models/hub_config.dart';
import '../models/vacuum_map.dart';

/// Error from the hub: HTTP status + the hub's `detail` message.
class HubApiException implements Exception {
  const HubApiException(this.statusCode, this.message);
  final int statusCode; // 0 = network error / unreachable
  final String message;

  bool get isForbidden => statusCode == 403;
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'HubApiException($statusCode): $message';
}

/// Event pushed on `/ws`.
class HubEvent {
  const HubEvent(this.type, this.data);
  final String type; // "devices" | "command" | ...
  final Map<String, dynamic> data;
}

/// Everything the app needs from the hub. Screens and state depend on this
/// interface only, so tests inject a fake.
abstract class HubApi {
  HubConfig get config;
  Future<Map<String, dynamic>> health();
  Future<Map<String, CapabilitySpec>> capabilities();
  Future<List<Device>> devices();
  Future<Device> device(String id);
  Future<Device> refresh(String id);
  Future<List<Device>> scan({bool lan = true, bool cloud = true});
  Future<Map<String, dynamic>> command(
    String id,
    String capability,
    String action, [
    Map<String, dynamic> params = const {},
  ]);
  Future<VacuumMap> vacuumMap(String id);
  Future<Map<String, dynamic>> integrations();
  Future<Map<String, dynamic>> roborockStatus();
  Future<Map<String, dynamic>> roborockRequestCode(String email);
  Future<Map<String, dynamic>> roborockLogin(String email, {String? code, String? password});
  Future<Map<String, dynamic>> roborockUnlink();

  /// Live events; the stream closes when the socket drops.
  Stream<HubEvent> events();
  void close();
}

class HttpHubApi implements HubApi {
  HttpHubApi(this.config, {http.Client? client}) : _client = client ?? http.Client();

  @override
  final HubConfig config;
  final http.Client _client;
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

  Map<String, dynamic> _map(dynamic d) => Map<String, dynamic>.from((d as Map?) ?? const {});
  List<Device> _devs(dynamic d) =>
      ((_map(d)['devices'] as List?) ?? const []).map((e) => Device.fromJson(Map<String, dynamic>.from(e))).toList();

  @override
  Future<Map<String, dynamic>> health() async =>
      _map(await _send('GET', '/health', timeout: const Duration(seconds: 5)));

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
