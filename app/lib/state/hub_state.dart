import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/hub_api.dart';
import '../models/capability_spec.dart';
import '../models/device.dart';
import '../models/hub_config.dart';
import 'settings_store.dart';

typedef HubApiFactory = HubApi Function(HubConfig config);

enum HubStatus { disconnected, connecting, connected, error }

/// App-wide hub session: connection, device list, capability catalog and live
/// updates. Plain ChangeNotifier (Provider) to keep things simple.
class HubState extends ChangeNotifier {
  HubState({required this.settings, required this.apiFactory});

  final SettingsStore settings;
  final HubApiFactory apiFactory;

  HubApi? _api;
  HubApi? get api => _api;
  HubStatus status = HubStatus.disconnected;
  String? error;
  String? hubName;
  bool scanning = false;
  bool liveConnected = false;
  Map<String, CapabilitySpec> specs = const {};
  final Map<String, Device> _devices = {};
  StreamSubscription<HubEvent>? _wsSub;
  Timer? _reconnect;
  int _wsBackoff = 1;
  bool _disposed = false;

  HubConfig? get config => _api?.config;
  List<Device> get devices => _devices.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  Device? device(String id) => _devices[id];

  /// Connects to [c] (verifies `/health`), loads catalog + devices, opens `/ws`.
  Future<bool> connect(HubConfig c, {bool remember = true}) async {
    _teardown();
    status = HubStatus.connecting;
    error = null;
    _notify();
    final api = apiFactory(c);
    try {
      final h = await api.health();
      hubName = h['name']?.toString();
      _api = api;
      specs = await api.capabilities();
      _setDevices(await api.devices());
      status = HubStatus.connected;
      if (remember) await settings.saveHub(c.copyWith(name: hubName));
      _openWs();
      _notify();
      return true;
    } on HubApiException catch (e) {
      api.close();
      _api = null;
      status = HubStatus.error;
      error = e.isUnauthorized ? '허브 비밀키가 올바르지 않습니다.' : e.message;
      _notify();
      return false;
    }
  }

  Future<bool> reconnectLast() async {
    final c = settings.loadHub();
    return c == null ? false : connect(c, remember: false);
  }

  Future<void> disconnect({bool forget = false}) async {
    _teardown();
    status = HubStatus.disconnected;
    _devices.clear();
    if (forget) await settings.clearHub();
    _notify();
  }

  Future<void> reload() async {
    final api = _api;
    if (api == null) return;
    _setDevices(await api.devices());
    _notify();
  }

  Future<void> scan() async {
    final api = _api;
    if (api == null || scanning) return;
    scanning = true;
    _notify();
    try {
      _setDevices(await api.scan());
    } finally {
      scanning = false;
      _notify();
    }
  }

  Future<Device?> refreshDevice(String id) async {
    final api = _api;
    if (api == null) return null;
    final d = await api.refresh(id);
    _devices[d.id] = d;
    _notify();
    return d;
  }

  /// Sends a canonical command, then re-reads the device. Throws
  /// [HubApiException] (e.g. 403 when an appliance's remote control is off).
  Future<Map<String, dynamic>> command(
    String id,
    String capability,
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    final api = _api;
    if (api == null) throw const HubApiException(0, '허브에 연결되어 있지 않습니다.');
    final res = await api.command(id, capability, action, params);
    try {
      final d = await api.device(id);
      _devices[d.id] = d;
      _notify();
    } catch (_) {}
    return res;
  }

  // ------------------------------------------------------------------ live --
  void _openWs() {
    final api = _api;
    if (api == null) return;
    _wsSub?.cancel();
    _wsSub = api.events().listen(_onEvent, onDone: _scheduleReconnect, onError: (_) => _scheduleReconnect());
  }

  void _onEvent(HubEvent e) {
    if (!liveConnected) {
      liveConnected = true;
      _wsBackoff = 1;
    }
    if (e.type == 'devices' && e.data['devices'] is List) {
      _setDevices((e.data['devices'] as List).map((d) => Device.fromJson(Map<String, dynamic>.from(d))).toList());
    } else if (e.type == 'command' && e.data['device'] is Map) {
      final d = Device.fromJson(Map<String, dynamic>.from(e.data['device']));
      _devices[d.id] = d;
    }
    _notify();
  }

  void _scheduleReconnect() {
    liveConnected = false;
    _notify();
    if (_api == null || _disposed) return;
    _reconnect?.cancel();
    _reconnect = Timer(Duration(seconds: _wsBackoff), _openWs);
    _wsBackoff = (_wsBackoff * 2).clamp(1, 30);
  }

  void _setDevices(List<Device> list) {
    _devices
      ..clear()
      ..addEntries(list.map((d) => MapEntry(d.id, d)));
  }

  void _teardown() {
    _reconnect?.cancel();
    _wsSub?.cancel();
    _wsSub = null;
    _api?.close();
    _api = null;
    liveConnected = false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _teardown();
    super.dispose();
  }
}
