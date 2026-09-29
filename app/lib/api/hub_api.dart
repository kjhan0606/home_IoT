import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../backend/device_backend.dart';
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

  // ---- automation rules: the hub is the always-on rules engine (hub mode only) ----
  Future<List<Map<String, dynamic>>> automationRules();
  Future<Map<String, dynamic>> saveAutomationRule(Map<String, dynamic> rule, {String? id});
  Future<void> deleteAutomationRule(String id);
  Future<Map<String, dynamic>> setAutomationRuleEnabled(String id, bool enabled);
  Future<List<Map<String, dynamic>>> automationLog({int limit = 50});
  Future<void> clearAutomationLog();

  /// 휴가/장기 외출 모드 (away plan, lights + curtains only). `plan` is null when none is set.
  Future<Map<String, dynamic>> awayGet();
  Future<Map<String, dynamic>> awaySet(Map<String, dynamic> plan);
  Future<void> awayStop();

  /// Fires a named event ('leaving', 'arriving', 'wake', 'alarm', ...) and returns the log entries it produced.
  Future<List<Map<String, dynamic>>> emitAutomationEvent(String name);
}

class HttpHubApi implements HubApi {
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

  List<Map<String, dynamic>> _maps(dynamic d, String key) =>
      ((_map(d)[key] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  @override
  Future<List<Map<String, dynamic>>> automationRules() async => _maps(await _send('GET', '/automation/rules'), 'rules');

  @override
  Future<Map<String, dynamic>> saveAutomationRule(Map<String, dynamic> rule, {String? id}) async => _map(
    await _send(
      id == null ? 'POST' : 'PUT',
      id == null ? '/automation/rules' : '/automation/rules/${Uri.encodeComponent(id)}',
      body: rule,
    ),
  );

  @override
  Future<void> deleteAutomationRule(String id) async {
    await _send('DELETE', '/automation/rules/${Uri.encodeComponent(id)}');
  }

  @override
  Future<Map<String, dynamic>> setAutomationRuleEnabled(String id, bool enabled) async =>
      _map(await _send('POST', '/automation/rules/${Uri.encodeComponent(id)}/enable', body: {'enabled': enabled}));

  @override
  Future<List<Map<String, dynamic>>> automationLog({int limit = 50}) async =>
      _maps(await _send('GET', '/automation/log', query: {'limit': '$limit'}), 'log');

  @override
  Future<void> clearAutomationLog() async {
    await _send('DELETE', '/automation/log');
  }

  @override
  Future<Map<String, dynamic>> awayGet() async => _map(await _send('GET', '/automation/away'));

  @override
  Future<Map<String, dynamic>> awaySet(Map<String, dynamic> plan) async =>
      _map(await _send('PUT', '/automation/away', body: plan));

  @override
  Future<void> awayStop() async {
    await _send('DELETE', '/automation/away', timeout: const Duration(seconds: 60));
  }

  @override
  Future<List<Map<String, dynamic>>> emitAutomationEvent(String name) async => _maps(
    await _send('POST', '/automation/events/${Uri.encodeComponent(name)}', timeout: const Duration(seconds: 60)),
    'fired',
  );

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
