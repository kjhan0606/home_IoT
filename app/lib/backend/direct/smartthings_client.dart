import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/device.dart';
import '../device_backend.dart';
import 'cloud_provider.dart';

/// Samsung SmartThings cloud client (official REST API) -- a Dart port of
/// `hub/homehub/adapters/smartthings.py`.
///
///   GET  /devices                (paginated via `_links.next.href`)
///   GET  /devices/{id}/status    `{"components": {comp: {cap: {attr: {"value","unit"}}}}}`
///   POST /devices/{id}/commands  `{"commands": [{component, capability, command, arguments}]}`
///
/// Auth is `Authorization: Bearer <PAT>`. NOTE: PATs created after 2024-12-30
/// are valid for **24 hours only**; a 401/403 is therefore reported as a
/// [CloudAuthException] that says so. OAuth (long-lived refresh tokens) needs
/// a client secret and therefore a small relay -- see docs/app-backends.md.
///
/// Translation SmartThings -> canonical capabilities (per component):
///   switch | light -> power; windowShade(+windowShadeLevel) -> curtain; audioVolume+audioMute -> volume; tvChannel -> channel;
///   (samsungvd.)mediaInputSource -> mediaInput; mediaPlayback(+mediaTrackControl)
///   -> mediaPlayback; switchLevel -> brightness; lock -> lock;
///   washer/dryerOperatingState(+remoteControlStatus, samsungce.*) -> washer/dryer;
///   refrigeration/temperatureMeasurement/thermostatCoolingSetpoint/contactSensor
///   (per cooler/freezer component) -> refrigeration;
///   robotCleanerMovement+robotCleanerCleaningMode+battery -> vacuum.
class SmartThingsClient implements CloudProvider {
  SmartThingsClient({
    required this.token,
    http.Client? client,
    String? baseUrl,
    this.timeout = const Duration(seconds: 15),
    DateTime Function()? now,
  }) : _http = client ?? http.Client(),
       baseUrl = (baseUrl ?? defaultBase).replaceAll(RegExp(r'/+$'), ''),
       _now = now ?? DateTime.now;

  static const defaultBase = 'https://api.smartthings.com/v1';
  static const providerId = 'smartthings';

  final TokenSupplier token;
  final String baseUrl;
  final Duration timeout;
  final http.Client _http;
  final DateTime Function() _now;

  @override
  String get id => providerId;
  @override
  String get name => 'Samsung SmartThings (cloud)';

  static const _categoryKind = {
    'television': 'tv',
    'washer': 'washer',
    'dryer': 'dryer',
    'refrigerator': 'refrigerator',
    'kimchirefrigerator': 'refrigerator',
    'robotcleaner': 'vacuum',
    'light': 'light',
    'curtain': 'curtain',
    'blind': 'curtain',
    'switch': 'switch',
    'smartplug': 'switch',
    'smartlock': 'lock',
    'speaker': 'speaker',
    'networkaudio': 'speaker',
    'airconditioner': 'air-conditioner',
    'dishwasher': 'dishwasher',
    'mobile': 'phone',
    'smartphone': 'phone',
  };

  /// robotCleanerMovement value -> canonical vacuum.status
  static const _vacuumStatus = {
    'cleaning': 'cleaning',
    'point': 'cleaning',
    'pause': 'paused',
    'homing': 'returning',
    'charging': 'charging',
    'alarm': 'error',
    'idle': 'idle',
    'after': 'idle',
    'reserve': 'idle',
    'powerOff': 'idle',
  };

  /// windowShade attribute value -> canonical curtain.status
  static const _shadeStatus = {
    'open': 'open',
    'closed': 'closed',
    'opening': 'opening',
    'closing': 'closing',
    'partially open': 'partial',
    'unknown': 'unknown',
  };

  static String _shadeStatusFromLevel(Object? level) {
    if (level is! num) return 'unknown';
    return level <= 0
        ? 'closed'
        : level >= 100
        ? 'open'
        : 'partial';
  }

  /// Enum from the robotCleanerCleaningMode capability definition.
  static const cleaningModes = ['auto', 'part', 'repeat', 'manual', 'stop', 'map'];

  static const _fridgeComps = ['cooler', 'fridge', 'onedoor'];
  static const _freezerComps = ['freezer'];

  static const _expiredHint =
      'SmartThings가 토큰을 거부했습니다. 2024-12-30 이후 발급된 개인용 토큰(PAT)은 24시간 뒤 만료됩니다. '
      '설정에서 새 토큰을 발급받아 입력하세요.';

  // ---------------------------------------------------------------- HTTP --
  Future<Map<String, dynamic>> _request(String method, String pathOrUrl, {Object? body}) async {
    final tok = (await token())?.trim();
    if (tok == null || tok.isEmpty) {
      throw const BackendException(503, 'SmartThings 토큰이 설정되지 않았습니다.');
    }
    final url = pathOrUrl.startsWith('http') ? Uri.parse(pathOrUrl) : Uri.parse('$baseUrl$pathOrUrl');
    final req = http.Request(method, url)
      ..headers['Authorization'] = 'Bearer $tok'
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(timeout));
    } on TimeoutException {
      throw const BackendException(0, 'SmartThings 응답 시간이 초과되었습니다.');
    } catch (e) {
      throw BackendException(0, 'SmartThings에 연결할 수 없습니다: $e');
    }
    final text = utf8.decode(res.bodyBytes);
    Object? data;
    try {
      data = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      data = text.length > 300 ? text.substring(0, 300) : text;
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw CloudAuthException(providerId, '$_expiredHint (${res.statusCode}: ${_short(data)})');
    }
    if (res.statusCode == 429) {
      throw const BackendException(429, 'SmartThings 요청이 너무 많습니다. 잠시 후 다시 시도하세요.');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendException(502, 'SmartThings $method $url -> ${res.statusCode}: ${_short(data)}');
    }
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  static String _short(Object? d) {
    final s = d is String ? d : jsonEncode(d);
    return s.length > 300 ? s.substring(0, 300) : s;
  }

  Future<Map<String, dynamic>> _getStatus(String deviceId) async =>
      asMap((await _request('GET', '/devices/$deviceId/status'))['components']);

  Future<Map<String, dynamic>> _send(
    Device device,
    String component,
    String capability,
    String command, [
    List<Object?> arguments = const [],
  ]) async {
    final resp = await _request(
      'POST',
      '/devices/${device.meta['cloudId']}/commands',
      body: {
        'commands': [
          {'component': component, 'capability': capability, 'command': command, 'arguments': arguments},
        ],
      },
    );
    return {
      'ok': true,
      'method': 'smartthings',
      'command': '$component/$capability.$command',
      'arguments': arguments,
      'response': resp['results'] ?? resp,
    };
  }

  // ------------------------------------------------- Rules API (Samsung cloud) --
  // Rules registered here run in SmartThings' own cloud (or locally on a Samsung hub) even when
  // this app is closed and without any server of ours. PAT scopes needed: r:rules:*, w:rules:*,
  // x:rules:* (plus devices/locations read). Unverified against a real account.

  /// The account's locations: `[{locationId, name, ...}]`.
  Future<List<Map<String, dynamic>>> locations() async =>
      asList((await _request('GET', '/locations'))['items']).map(asMap).toList();

  /// IANA time zone id of a location (rule times are interpreted in it), or null.
  Future<String?> locationTimeZone(String locationId) async {
    try {
      return asMap(await _request('GET', '/locations/$locationId'))['timeZoneId'] as String?;
    } on BackendException {
      return null;
    }
  }

  /// Registers [rule] (a Rules API JSON document). Returns the created rule's id.
  Future<String> createRule(String locationId, Map<String, dynamic> rule) async {
    final res = await _request('POST', '/rules?locationId=$locationId', body: rule);
    final id = res['id'];
    if (id is! String || id.isEmpty) throw const BackendException(502, 'SmartThings가 규칙 id를 돌려주지 않았습니다.');
    return id;
  }

  Future<void> deleteRule(String locationId, String ruleId) async {
    await _request('DELETE', '/rules/$ruleId?locationId=$locationId');
  }

  Future<List<Map<String, dynamic>>> listRules(String locationId) async =>
      asList((await _request('GET', '/rules?locationId=$locationId'))['items']).map(asMap).toList();

  // ------------------------------------------------------------ discovery --
  @override
  Future<List<Device>> listDevices() async {
    final items = <Map<String, dynamic>>[];
    String? url = '/devices';
    while (url != null) {
      final page = await _request('GET', url);
      items.addAll(asList(page['items']).map(asMap));
      url = asMap(asMap(page['_links'])['next'])['href'] as String?;
    }
    return Future.wait(
      items.map((item) async {
        Map<String, dynamic> status;
        try {
          status = await _getStatus(item['deviceId'] as String);
        } on CloudAuthException {
          rethrow;
        } catch (_) {
          status = {}; // offline device: list it anyway
        }
        return deviceFromItem(item, status);
      }),
    );
  }

  @override
  Future<Device> refresh(Device device) async {
    final status = await _getStatus(device.meta['cloudId'] as String);
    final compCaps = _compCapsFromMeta(device);
    final (caps, _) = _translate(compCaps, status, device.kind);
    final merged = {
      for (final e in device.capabilities.entries)
        e.key: caps.containsKey(e.key)
            ? CapabilityInstance(key: e.key, actions: e.value.actions, state: caps[e.key]!.state)
            : e.value,
    };
    return device.copyWith(capabilities: merged, reachable: true);
  }

  static Map<String, Set<String>> _compCapsFromMeta(Device d) => {
    for (final e in asMap(d.meta['stCapabilities']).entries) e.key: asList(e.value).map((x) => '$x').toSet(),
  };

  // ---------------------------------------------------------- translation --
  /// Public for tests: builds a canonical [Device] from a `/devices` item and
  /// its `/status` components.
  Device deviceFromItem(Map<String, dynamic> item, Map<String, dynamic> status) {
    final compCaps = <String, Set<String>>{};
    var categories = <String>[];
    for (final comp in asList(item['components']).map(asMap)) {
      final cid = (comp['id'] as String?) ?? 'main';
      compCaps[cid] = asList(comp['capabilities']).map((c) => '${asMap(c)['id']}').toSet();
      if (comp['id'] == 'main') {
        categories = asList(comp['categories']).map((c) => '${asMap(c)['name'] ?? ''}').toList();
      }
    }
    if (compCaps.isEmpty) {
      // Listing lacked components: infer from status.
      for (final e in status.entries) {
        compCaps[e.key] = asMap(e.value).keys.toSet();
      }
    }

    final kind = _kind(categories, compCaps);
    final (caps, components) = _translate(compCaps, status, kind);
    final ocf = asMap(item['ocf']);
    final brand = _firstNonEmpty([item['manufacturerName'], ocf['manufacturerName']]) ?? '';
    final model = _firstNonEmpty([ocf['modelNumber'], item['deviceTypeName']]);
    final deviceId = item['deviceId'] as String;
    final name = _firstNonEmpty([item['label'], item['name']]) ?? deviceId;
    final health = asMap(item['healthState'])['state'];
    return Device(
      id: '$providerId:$deviceId',
      name: name,
      adapter: providerId,
      kind: kind,
      reachable: health != 'OFFLINE',
      controllable: caps.isNotEmpty,
      capabilities: caps,
      meta: {
        'cloudId': deviceId,
        'source': 'cloud',
        'vendor': brand.isEmpty ? null : brand,
        'model': model,
        'components': components, // canonical cap(.part) -> ST component
        'stCapabilities': {for (final e in compCaps.entries) e.key: (e.value.toList()..sort())},
        'categories': categories,
        'match': {'brand': brand, 'model': model, 'name': name, 'mac': null},
      },
    );
  }

  static String? _firstNonEmpty(List<Object?> xs) {
    for (final x in xs) {
      if (x is String && x.isNotEmpty) return x;
    }
    return null;
  }

  static String _kind(List<String> categories, Map<String, Set<String>> compCaps) {
    for (final c in categories) {
      final k = _categoryKind[c.replaceAll(' ', '').toLowerCase()];
      if (k != null) return k;
    }
    final all = compCaps.values.fold<Set<String>>({}, (a, b) => a..addAll(b));
    if (all.contains('washerOperatingState')) return 'washer';
    if (all.contains('dryerOperatingState')) return 'dryer';
    if (all.contains('refrigeration') || compCaps.containsKey('cooler') || compCaps.containsKey('freezer')) {
      return 'refrigerator';
    }
    if (all.contains('robotCleanerMovement')) return 'vacuum';
    if (all.contains('tvChannel')) return 'tv';
    if (all.contains('windowShade') || all.contains('windowShadeLevel')) return 'curtain';
    if (all.contains('switch') || all.contains('light')) return 'switch';
    return 'unknown';
  }

  int? _minutesUntil(String iso) {
    var s = iso.trim();
    // Python treats naive timestamps as UTC; Dart would treat them as local.
    if (!RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(s)) s = '${s}Z';
    final t = DateTime.tryParse(s);
    if (t == null) return null;
    final secs = t.difference(_now().toUtc()).inMilliseconds / 1000;
    final m = (secs / 60).ceil();
    return m < 0 ? 0 : m;
  }

  (Map<String, CapabilityInstance>, Map<String, String>) _translate(
    Map<String, Set<String>> compCaps,
    Map<String, dynamic> st,
    String kind,
  ) {
    Object? val(String? comp, String capability, String attr, [Object? dflt]) {
      if (comp == null) return dflt;
      final v = asMap(asMap(asMap(st[comp])[capability])[attr]);
      return v.containsKey('value') ? v['value'] : dflt;
    }

    String? unit(String comp, String capability, String attr) =>
        asMap(asMap(asMap(st[comp])[capability])[attr])['unit'] as String?;

    final main = compCaps['main'] ?? <String>{};
    final caps = <String, CapabilityInstance>{};
    final comps = <String, String>{};

    void add(String key, List<String> actions, Map<String, dynamic> state, [String comp = 'main']) {
      caps[key] = CapabilityInstance(key: key, actions: actions, state: state);
      comps[key] = comp;
    }

    if (main.contains('switch')) {
      add('power', ['turnOn', 'turnOff', 'toggle'], {'switch': val('main', 'switch', 'switch', 'unknown')});
    } else if (main.contains('light')) {
      // Legacy ST "light" capability: same on/off commands and `switch` attribute.
      add('power', ['turnOn', 'turnOff', 'toggle'], {'switch': val('main', 'light', 'switch', 'unknown')});
      comps['power.st'] = 'light';
    }

    // ---- curtain / blind -------------------------------------------------
    if (main.contains('windowShade') || main.contains('windowShadeLevel')) {
      final acts = <String>[];
      if (main.contains('windowShade')) {
        final sup = val('main', 'windowShade', 'supportedWindowShadeCommands');
        final supported = (sup is List && sup.isNotEmpty ? sup : ['open', 'close', 'pause']).map((e) => '$e').toSet();
        for (final (a, c) in const [('open', 'open'), ('close', 'close'), ('stop', 'pause')]) {
          if (supported.contains(c)) acts.add(a);
        }
      }
      if (main.contains('windowShadeLevel')) {
        acts.add('setPosition');
        if (!acts.contains('open') && !acts.contains('close')) acts.addAll(['open', 'close']); // emulate with 100 / 0
      }
      final level = main.contains('windowShadeLevel') ? val('main', 'windowShadeLevel', 'shadeLevel') : null;
      final stateStr = main.contains('windowShade') ? val('main', 'windowShade', 'windowShade') : null;
      add('curtain', acts, {
        'position': level is num ? level.toInt() : null,
        'status': _shadeStatus[stateStr] ?? _shadeStatusFromLevel(level),
      });
    }

    if (main.contains('audioVolume') || main.contains('audioMute')) {
      final acts = <String>[];
      if (main.contains('audioVolume')) acts.addAll(['setLevel', 'volumeUp', 'volumeDown']);
      if (main.contains('audioMute')) acts.addAll(['mute', 'unmute']);
      add('volume', acts, {
        'level': val('main', 'audioVolume', 'volume'),
        'muted': boolStr(val('main', 'audioMute', 'mute')),
      });
    }

    if (main.contains('tvChannel')) {
      add('channel', ['channelUp', 'channelDown', 'setChannel'], {'channel': val('main', 'tvChannel', 'tvChannel')});
    }

    if (main.contains('samsungvd.mediaInputSource')) {
      final smap = asList(val('main', 'samsungvd.mediaInputSource', 'supportedInputSourcesMap'));
      final sources = [
        for (final s in smap)
          if (s is Map && s['id'] != null && '${s['id']}'.isNotEmpty) '${s['id']}',
      ];
      add(
        'mediaInput',
        ['select'],
        {'sources': sources, 'selected': val('main', 'samsungvd.mediaInputSource', 'inputSource')},
      );
      comps['mediaInput.st'] = 'samsungvd.mediaInputSource';
    } else if (main.contains('mediaInputSource')) {
      add(
        'mediaInput',
        ['select'],
        {
          'sources': asList(val('main', 'mediaInputSource', 'supportedInputSources')).map((e) => '$e').toList(),
          'selected': val('main', 'mediaInputSource', 'inputSource'),
        },
      );
      comps['mediaInput.st'] = 'mediaInputSource';
    }

    if (main.contains('mediaPlayback')) {
      final acts = ['play', 'pause', 'stop'];
      if (main.contains('mediaTrackControl')) acts.addAll(['next', 'previous']);
      add('mediaPlayback', acts, {'status': val('main', 'mediaPlayback', 'playbackStatus')});
    }

    if (main.contains('switchLevel')) {
      add('brightness', ['setLevel'], {'level': val('main', 'switchLevel', 'level')});
    }
    if (main.contains('lock')) {
      add('lock', ['lock', 'unlock'], {'locked': val('main', 'lock', 'lock') == 'locked'});
    }

    // ---- laundry ---------------------------------------------------------
    for (final (key, stCap, jobAttr) in const [
      ('washer', 'washerOperatingState', 'washerJobState'),
      ('dryer', 'dryerOperatingState', 'dryerJobState'),
    ]) {
      if (!main.contains(stCap)) continue;
      final machine = val('main', stCap, 'machineState');
      final supportedRaw = val('main', stCap, 'supportedMachineStates');
      final supported = (supportedRaw is List && supportedRaw.isNotEmpty ? supportedRaw : ['run', 'pause', 'stop'])
          .map((e) => '$e')
          .toList();
      final acts = [
        for (final (a, s) in const [('start', 'run'), ('pause', 'pause'), ('stop', 'stop')])
          if (supported.contains(s)) a,
      ];
      final completion = val('main', stCap, 'completionTime');
      int? remaining;
      final sce = 'samsungce.$stCap';
      final sceRemaining = main.contains(sce) ? val('main', sce, 'remainingTime') : null;
      if (sceRemaining != null) {
        remaining = sceRemaining is num ? sceRemaining.toInt() : int.tryParse('$sceRemaining');
      } else if (machine == 'run' && completion is String && completion.isNotEmpty) {
        remaining = _minutesUntil(completion);
      } else if (machine == 'stop') {
        remaining = 0;
      }
      add(key, acts, {
        'machineState': machine,
        'jobState': val('main', stCap, jobAttr),
        'remainingMinutes': remaining,
        'completionTime': completion,
        'remoteControlEnabled': main.contains('remoteControlStatus')
            ? boolStr(val('main', 'remoteControlStatus', 'remoteControlEnabled'))
            : null,
      });
    }

    // ---- refrigerator ----------------------------------------------------
    String? fridgeC = _fridgeComps.where(compCaps.containsKey).firstOrNull;
    final freezerC = _freezerComps.where(compCaps.containsKey).firstOrNull;
    if (fridgeC == null && kind == 'refrigerator' && main.contains('thermostatCoolingSetpoint')) fridgeC = 'main';
    if (main.contains('refrigeration') || fridgeC != null || freezerC != null) {
      final acts = <String>[];
      final state = <String, dynamic>{'unit': null};
      final doors = <String, bool>{};
      for (final (part, comp) in [('fridge', fridgeC), ('freezer', freezerC)]) {
        final cc = comp != null ? (compCaps[comp] ?? <String>{}) : <String>{};
        state['${part}Temperature'] = comp != null ? val(comp, 'temperatureMeasurement', 'temperature') : null;
        state['${part}Setpoint'] = comp != null ? val(comp, 'thermostatCoolingSetpoint', 'coolingSetpoint') : null;
        if (comp != null && cc.contains('thermostatCoolingSetpoint')) {
          acts.add(part == 'fridge' ? 'setFridgeSetpoint' : 'setFreezerSetpoint');
          comps['refrigeration.$part'] = comp;
          state['unit'] ??= unit(comp, 'thermostatCoolingSetpoint', 'coolingSetpoint');
        }
        if (comp != null) state['unit'] ??= unit(comp, 'temperatureMeasurement', 'temperature');
      }
      for (final e in compCaps.entries) {
        if (e.value.contains('contactSensor') && (e.key == 'main' || e.key == fridgeC || e.key == freezerC)) {
          doors[e.key] = val(e.key, 'contactSensor', 'contact') == 'open';
        }
      }
      state['doors'] = doors;
      state['doorOpen'] = doors.isNotEmpty ? doors.values.any((v) => v) : null;
      if (main.contains('refrigeration')) {
        acts.addAll(['setRapidCooling', 'setRapidFreezing']);
        state['rapidCooling'] = boolStr(val('main', 'refrigeration', 'rapidCooling'));
        state['rapidFreezing'] = boolStr(val('main', 'refrigeration', 'rapidFreezing'));
      } else {
        // ASSUMPTION (same as the hub): samsungce.powerCool/powerFreeze expose
        // an "activated" attribute + activate/deactivate commands.
        state['rapidCooling'] = boolStr(val('main', 'samsungce.powerCool', 'activated'));
        state['rapidFreezing'] = boolStr(val('main', 'samsungce.powerFreeze', 'activated'));
        if (main.contains('samsungce.powerCool')) acts.add('setRapidCooling');
        if (main.contains('samsungce.powerFreeze')) acts.add('setRapidFreezing');
      }
      state['unit'] ??= 'C';
      add('refrigeration', acts, state);
    }

    // ---- robot vacuum ----------------------------------------------------
    if (main.contains('robotCleanerMovement') || main.contains('robotCleanerCleaningMode')) {
      final movement = val('main', 'robotCleanerMovement', 'robotCleanerMovement');
      final acts = <String>[];
      if (main.contains('robotCleanerMovement')) acts.addAll(['start', 'pause', 'dock']);
      if (main.contains('robotCleanerCleaningMode')) {
        acts.addAll(['stop', 'setCleaningMode']);
        if (!acts.contains('start')) acts.insert(0, 'start');
      }
      add('vacuum', acts, {
        'status': _vacuumStatus[movement ?? ''] ?? 'idle',
        'battery': main.contains('battery') ? val('main', 'battery', 'battery') : null,
        'cleaningMode': val('main', 'robotCleanerCleaningMode', 'robotCleanerCleaningMode'),
        'cleaningModes': main.contains('robotCleanerCleaningMode') ? List<String>.of(cleaningModes) : <String>[],
      });
    }

    return (caps, comps);
  }

  // ------------------------------------------------------------- control --
  @override
  Future<Map<String, dynamic>> execute(
    Device device,
    String capability,
    String action,
    Map<String, dynamic> params,
  ) async {
    validateAction(capability, action);
    final compMap = asMap(device.meta['components']);
    final comp = (compMap[capability] as String?) ?? 'main';
    final stCaps = asList(asMap(device.meta['stCapabilities'])['main']).map((e) => '$e').toSet();

    switch (capability) {
      case 'power':
        var a = action;
        if (a == 'toggle') {
          final cur = device.capabilities['power']?.state['switch'];
          a = cur == 'on' ? 'turnOff' : 'turnOn';
        }
        return _send(device, comp, (compMap['power.st'] as String?) ?? 'switch', a == 'turnOn' ? 'on' : 'off');

      case 'curtain':
        final hasShade = stCaps.contains('windowShade');
        final hasLevel = stCaps.contains('windowShadeLevel');
        if (action == 'setPosition') {
          return _send(device, comp, 'windowShadeLevel', 'setShadeLevel', [intParam(params, 'position', 0, 100)]);
        }
        if ((action == 'open' || action == 'close') && !hasShade && hasLevel) {
          return _send(device, comp, 'windowShadeLevel', 'setShadeLevel', [action == 'open' ? 100 : 0]);
        }
        return _send(device, comp, 'windowShade', const {'open': 'open', 'close': 'close', 'stop': 'pause'}[action]!);

      case 'volume':
        if (action == 'setLevel') {
          return _send(device, comp, 'audioVolume', 'setVolume', [intParam(params, 'level', 0, 100)]);
        }
        if (action == 'volumeUp' || action == 'volumeDown') return _send(device, comp, 'audioVolume', action);
        return _send(device, comp, 'audioMute', action); // mute / unmute

      case 'channel':
        if (action == 'setChannel') {
          final ch = '${params['channel'] ?? ''}'.trim();
          if (ch.isEmpty) throw const BackendException(400, "setChannel requires 'channel'");
          return _send(device, comp, 'tvChannel', 'setTvChannel', [ch]);
        }
        return _send(device, comp, 'tvChannel', action);

      case 'mediaInput':
        final src = '${params['source'] ?? ''}'.trim();
        if (src.isEmpty) throw const BackendException(400, "select requires 'source'");
        final stCap = (compMap['mediaInput.st'] as String?) ?? 'mediaInputSource';
        return _send(device, comp, stCap, 'setInputSource', [src]);

      case 'mediaPlayback':
        if (action == 'next' || action == 'previous') {
          return _send(device, comp, 'mediaTrackControl', '${action}Track');
        }
        return _send(device, comp, 'mediaPlayback', action);

      case 'brightness':
        return _send(device, comp, 'switchLevel', 'setLevel', [intParam(params, 'level', 0, 100)]);

      case 'lock':
        return _send(device, comp, 'lock', action);

      case 'washer':
      case 'dryer':
        final stCap = capability == 'washer' ? 'washerOperatingState' : 'dryerOperatingState';
        if (action == 'start') {
          // Re-read the live flag: the user may have toggled it since the last sync.
          final live = await _getStatus(device.meta['cloudId'] as String);
          bool? flag;
          if (stCaps.contains('remoteControlStatus')) {
            final v = asMap(asMap(asMap(live['main'])['remoteControlStatus'])['remoteControlEnabled'])['value'];
            flag = boolStr(v);
          }
          requireRemoteStart(flag, device);
        }
        final state = const {'start': 'run', 'pause': 'pause', 'stop': 'stop'}[action]!;
        return _send(device, comp, stCap, 'setMachineState', [state]);

      case 'refrigeration':
        if (action == 'setFridgeSetpoint' || action == 'setFreezerSetpoint') {
          final part = action == 'setFridgeSetpoint' ? 'fridge' : 'freezer';
          final target = compMap['refrigeration.$part'] as String?;
          if (target == null) throw BackendException(400, 'device has no controllable $part compartment');
          return _send(device, target, 'thermostatCoolingSetpoint', 'setCoolingSetpoint', [
            numParam(params, 'temperature'),
          ]);
        }
        final enabled = boolParam(params, 'enabled');
        if (stCaps.contains('refrigeration')) {
          final cmd = action == 'setRapidCooling' ? 'setRapidCooling' : 'setRapidFreezing';
          return _send(device, 'main', 'refrigeration', cmd, [enabled ? 'on' : 'off']);
        }
        final sce = action == 'setRapidCooling' ? 'samsungce.powerCool' : 'samsungce.powerFreeze';
        return _send(device, 'main', sce, enabled ? 'activate' : 'deactivate');

      case 'vacuum':
        // ASSUMPTION (same as the hub): standard robotCleaner* capabilities
        // accept these enum values as commands. Newer Samsung Jet Bots use
        // samsungce.robotCleanerOperatingState, which is not handled yet.
        if (action == 'setCleaningMode') {
          final mode = '${params['mode'] ?? ''}'.trim();
          if (!cleaningModes.contains(mode)) throw BackendException(400, 'mode must be one of $cleaningModes');
          return _send(device, comp, 'robotCleanerCleaningMode', 'setRobotCleanerCleaningMode', [mode]);
        }
        if (action == 'stop') {
          return _send(device, comp, 'robotCleanerCleaningMode', 'setRobotCleanerCleaningMode', ['stop']);
        }
        if (action == 'start' && !stCaps.contains('robotCleanerMovement')) {
          return _send(device, comp, 'robotCleanerCleaningMode', 'setRobotCleanerCleaningMode', ['auto']);
        }
        final movement = const {'start': 'cleaning', 'pause': 'pause', 'dock': 'homing'}[action]!;
        return _send(device, comp, 'robotCleanerMovement', 'setRobotCleanerMovement', [movement]);
    }
    throw BackendException(400, 'unsupported: $capability.$action');
  }

  @override
  void close() => _http.close();
}
