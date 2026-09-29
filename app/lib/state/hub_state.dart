import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/hub_api.dart';
import '../backend/device_backend.dart';
import '../backend/direct/direct_factory.dart';
import '../models/capability_spec.dart';
import '../models/device.dart';
import '../models/hub_config.dart';
import 'credentials_store.dart';
import 'settings_store.dart';

typedef HubApiFactory = HubApi Function(HubConfig config);

enum HubStatus { disconnected, connecting, connected, error }

/// App-wide session over the active [DeviceBackend]: device list, capability
/// catalog, live updates / polling. Plain ChangeNotifier (Provider).
///
/// The name is historical -- this now serves every backend. Screens use
/// [devices], [command], [refreshDevice] etc. and never branch on the brand;
/// the only mode-aware bits are settings/onboarding (which tokens to ask for).
class HubState extends ChangeNotifier {
  HubState({
    required this.settings,
    required this.apiFactory,
    CredentialsStore? credentials,
    DirectBackendFactory? directFactory,
    DateTime Function()? now,
  }) : credentials = credentials ?? CredentialsStore(MemorySecretStore()),
       directFactory = directFactory ?? defaultDirectBackendFactory,
       _now = now ?? DateTime.now;

  final SettingsStore settings;
  final HubApiFactory apiFactory;

  /// Vendor tokens (Keychain). Used by direct-cloud mode.
  final CredentialsStore credentials;
  final DirectBackendFactory directFactory;
  final DateTime Function() _now;

  DeviceBackend? _backend;
  DeviceBackend? get backend => _backend;

  /// The hub client when the active backend is the hub (settings screens for
  /// Roborock/integrations need it); null in every other mode.
  HubApi? get api => _backend is HubApi ? _backend as HubApi : null;

  HubStatus status = HubStatus.disconnected;
  String? error;
  bool scanning = false;
  bool liveConnected = false;
  Map<String, CapabilitySpec> specs = const {};
  CloudCredentials creds = const CloudCredentials();
  final Map<String, Device> _devices = {};
  StreamSubscription<BackendEvent>? _wsSub;
  Timer? _reconnect;
  Timer? _poll;
  int _wsBackoff = 1;
  bool _disposed = false;
  bool _foreground = true;
  bool _syncing = false;

  BackendKind get mode => _backend?.kind ?? settings.mode;
  String? get hubName => _backend?.title;
  HubConfig? get config => api?.config;
  List<Device> get devices => _devices.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  Device? device(String id) => _devices[id];

  /// Per-integration problems from the last sync (id -> Korean message).
  Map<String, String> get warnings => _backend?.warnings ?? const {};

  /// True if the stored SmartThings PAT was entered >= 24 h ago (so it has
  /// most likely expired even if no request has failed yet).
  bool get smartThingsLikelyExpired => creds.smartThingsLikelyExpired(_now());

  // ------------------------------------------------------------ startup ----
  /// Starts the remembered mode (app launch).
  Future<void> start() async {
    creds = await credentials.load();
    if (settings.mode == BackendKind.hub) {
      final c = settings.loadHub();
      if (c != null) await connect(c, remember: false);
    } else if (creds.hasAny) {
      await startDirect();
    }
    _notify();
  }

  /// Kept for older call sites/tests: reconnect to the last hub.
  Future<bool> reconnectLast() async {
    final c = settings.loadHub();
    return c == null ? false : connect(c, remember: false);
  }

  // ------------------------------------------------------- direct cloud ----
  /// Builds the direct-cloud backend from the stored tokens and loads devices.
  /// A failing sync (e.g. expired SmartThings PAT) keeps the app "connected"
  /// with an error/warning banner so the user can fix the token in place.
  Future<bool> startDirect() async {
    _teardown();
    creds = await credentials.load();
    if (!creds.hasAny) {
      status = HubStatus.disconnected;
      _devices.clear();
      _notify();
      return false;
    }
    status = HubStatus.connecting;
    error = null;
    _notify();
    final backend = await directFactory(credentials);
    _backend = backend;
    specs = await backend.capabilities();
    await settings.setMode(BackendKind.directCloud);
    try {
      _setDevices(await backend.sync());
    } on BackendException catch (e) {
      _devices.clear();
      error = e.message;
    }
    status = HubStatus.connected;
    _startPolling();
    _notify();
    return true;
  }

  /// Saves tokens (Keychain) and (re)starts direct mode. Pass null to leave a
  /// token untouched; pass an empty string to remove it.
  Future<bool> saveTokens({String? smartThings, String? lgToken, String? lgCountry}) async {
    if (smartThings != null) {
      smartThings.trim().isEmpty
          ? await credentials.clearSmartThings()
          : await credentials.saveSmartThings(smartThings);
    }
    if (lgToken != null) {
      lgToken.trim().isEmpty
          ? await credentials.clearLg()
          : await credentials.saveLg(lgToken, lgCountry ?? (await credentials.load()).lgCountry);
    } else if (lgCountry != null && (await credentials.load()).hasLg) {
      await credentials.saveLg((await credentials.lgToken())!, lgCountry);
    }
    return startDirect();
  }

  // ---------------------------------------------------------------- hub ----
  /// Connects to [c] (verifies `/health`), loads catalog + devices, opens `/ws`.
  Future<bool> connect(HubConfig c, {bool remember = true}) async {
    _teardown();
    status = HubStatus.connecting;
    error = null;
    _notify();
    final api = apiFactory(c);
    try {
      await api.health();
      _backend = api;
      specs = await api.capabilities();
      _setDevices(await api.devices());
      status = HubStatus.connected;
      await settings.setMode(BackendKind.hub);
      if (remember) await settings.saveHub(c.copyWith(name: api.title));
      _openWs();
      _notify();
      return true;
    } on BackendException catch (e) {
      api.close();
      _backend = null;
      status = HubStatus.error;
      error = e.isUnauthorized ? '허브 비밀키가 올바르지 않습니다.' : e.message;
      _notify();
      return false;
    }
  }

  Future<void> disconnect({bool forget = false}) async {
    _teardown();
    status = HubStatus.disconnected;
    _devices.clear();
    if (forget) await settings.clearHub();
    _notify();
  }

  /// Switches mode from settings: tears the session down; the caller then
  /// connects (hub) or [startDirect]s.
  Future<void> selectMode(BackendKind m) async {
    if (m == mode && _backend != null) return;
    _teardown();
    _devices.clear();
    status = HubStatus.disconnected;
    await settings.setMode(m);
    _notify();
    if (m == BackendKind.directCloud) {
      await startDirect();
    } else {
      final c = settings.loadHub();
      if (c != null) await connect(c, remember: false);
    }
  }

  // ------------------------------------------------------------ devices ----
  /// Re-reads everything from the source (pull to refresh / polling).
  Future<void> reload() async {
    final b = _backend;
    if (b == null) return;
    final list = await b.sync();
    _setDevices(list);
    _notify();
  }

  Future<void> scan() async {
    final b = _backend;
    if (b == null || scanning) return;
    scanning = true;
    _notify();
    try {
      _setDevices(await b.scan());
      error = null;
    } finally {
      scanning = false;
      _notify();
    }
  }

  Future<Device?> refreshDevice(String id) async {
    final b = _backend;
    if (b == null) return null;
    final d = await b.refresh(id);
    _devices[d.id] = d;
    _notify();
    return d;
  }

  /// Sends a canonical command, then re-reads the device. Throws
  /// [BackendException] (e.g. 403 when an appliance's remote control is off).
  Future<Map<String, dynamic>> command(
    String id,
    String capability,
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    final b = _backend;
    if (b == null) throw const BackendException(0, '연결되어 있지 않습니다.');
    final res = await b.command(id, capability, action, params);
    try {
      final d = await b.device(id);
      _devices[d.id] = d;
      _notify();
    } catch (_) {}
    return res;
  }

  // ------------------------------------------------------ live / polling ----
  /// Pauses polling while the app is in the background (saves cloud quota).
  void setForeground(bool v) {
    if (_foreground == v) return;
    _foreground = v;
    if (v && _poll != null) unawaited(_pollOnce());
  }

  void _startPolling() {
    _poll?.cancel();
    final every = _backend?.pollInterval;
    if (every == null) return;
    _poll = Timer.periodic(every, (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    if (!_foreground || _syncing || _backend == null || _disposed) return;
    _syncing = true;
    try {
      _setDevices(await _backend!.sync());
      error = null;
      _notify();
    } on BackendException catch (e) {
      error = e.message;
      _notify();
    } finally {
      _syncing = false;
    }
  }

  void _openWs() {
    final b = _backend;
    if (b == null || !b.hasEventStream) return;
    _wsSub?.cancel();
    _wsSub = b.events().listen(_onEvent, onDone: _scheduleReconnect, onError: (_) => _scheduleReconnect());
  }

  void _onEvent(BackendEvent e) {
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
    if (_backend == null || _disposed) return;
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
    _poll?.cancel();
    _poll = null;
    _wsSub?.cancel();
    _wsSub = null;
    _backend?.close();
    _backend = null;
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
