import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../models/device.dart';
import '../device_backend.dart';
import 'cloud_provider.dart';

/// LG ThinQ Connect cloud client (official LG API for individuals) -- a Dart
/// port of `hub/homehub/adapters/lg_thinq.py`, which mirrors LG's Apache-2.0
/// `thinq-connect/pythinqconnect` SDK.
///
///   Base URL : https://api-{region}.lgthinq.com  (kic = KR & Asia-Pacific,
///              aic = Americas, eic = Europe/Middle-East/Africa; from x-country)
///   Headers  : Authorization: Bearer `<PAT>`, x-country, x-message-id (fresh
///              22-char base64url of a UUID per request), x-client-id (stable per
///              install), x-api-key (public key from LG's SDK), x-service-phase: OP;
///              control calls add x-conditional-control: true.
///   GET  /devices               -> response: [{deviceId, deviceInfo:{deviceType, modelName, alias}}]
///   GET  /devices/{id}/profile  -> response: {property: ...}  (r/w modes + allowed values)
///   GET  /devices/{id}/state    -> response: current state
///   POST /devices/{id}/control  -> body: {resource: {property: value}} (+ location)
///
/// ThinQ Connect does NOT cover LG TVs. The enum *values* used for commands
/// are ASSUMPTIONS taken from the SDK / Home Assistant (same as the hub); the
/// device's /profile is read so only writable actions are offered.
class LgThinqClient implements CloudProvider {
  LgThinqClient({
    required this.token,
    required this.country,
    required this.clientId,
    http.Client? client,
    this.baseUrlOverride,
    String? apiKey,
    this.timeout = const Duration(seconds: 15),
    Random? random,
  }) : _http = client ?? http.Client(),
       _apiKey = apiKey ?? defaultApiKey,
       _rng = random ?? Random.secure();

  static const providerId = 'lg_thinq';

  /// Public client key shipped in LG's official SDK (thinqconnect/const.py API_KEY).
  static const defaultApiKey = 'v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3';

  final TokenSupplier token;
  final String country;
  final String clientId;
  final Duration timeout;
  final http.Client _http;
  final String? baseUrlOverride;
  final String _apiKey;
  final Random _rng;

  @override
  String get id => providerId;
  @override
  String get name => 'LG ThinQ (cloud)';

  static const _kic = {
    'AU',
    'BD',
    'CN',
    'HK',
    'ID',
    'IN',
    'JP',
    'KH',
    'KR',
    'LA',
    'LK',
    'MM',
    'MY', //
    'NP', 'NZ', 'PH', 'SG', 'TH', 'TW', 'VN',
  };
  static const _aic = {
    'AG',
    'AR',
    'AW',
    'BB',
    'BO',
    'BR',
    'BS',
    'BZ',
    'CA',
    'CL',
    'CO',
    'CR',
    'CU',
    'DM',
    'DO',
    'EC', //
    'GD',
    'GT',
    'GY',
    'HN',
    'HT',
    'JM',
    'KN',
    'LC',
    'MX',
    'NI',
    'PA',
    'PE',
    'PR',
    'PY',
    'SR',
    'SV',
    'TT', 'US', 'UY', 'VC', 'VE',
  };

  static String regionForCountry(String country) {
    final c = country.toUpperCase();
    if (_kic.contains(c)) return 'kic';
    if (_aic.contains(c)) return 'aic';
    return 'eic';
  }

  String get _country => (country.trim().isEmpty ? 'KR' : country.trim()).toUpperCase();
  String get baseUrl =>
      (baseUrlOverride ?? 'https://api-${regionForCountry(_country)}.lgthinq.com').replaceAll(RegExp(r'/+$'), '');

  static const _typeKind = {
    'DEVICE_WASHER': 'washer',
    'DEVICE_WASHTOWER_WASHER': 'washer',
    'DEVICE_WASHCOMBO_MAIN': 'washer',
    'DEVICE_WASHCOMBO_MINI': 'washer',
    'DEVICE_DRYER': 'dryer',
    'DEVICE_WASHTOWER_DRYER': 'dryer',
    'DEVICE_REFRIGERATOR': 'refrigerator',
    'DEVICE_ROBOT_CLEANER': 'vacuum',
  };

  /// Known but not (yet) mapped to canonical capabilities -> listed as passive.
  static const _typeKindPassive = {
    'DEVICE_WASHTOWER': 'washer-dryer',
    'DEVICE_KIMCHI_REFRIGERATOR': 'refrigerator',
    'DEVICE_STYLER': 'styler',
    'DEVICE_DISH_WASHER': 'dishwasher',
    'DEVICE_AIR_CONDITIONER': 'air-conditioner',
    'DEVICE_AIR_PURIFIER': 'air-purifier',
    'DEVICE_OVEN': 'oven',
  };

  // ASSUMPTION (as on the hub): START / STOP / POWER_OFF for washer/dryerOperationMode.
  // LG uses "STOP" to pause a running course; a course can only be ended
  // remotely by powering the machine off.
  static const _laundryActionValue = {'start': 'START', 'pause': 'STOP', 'stop': 'POWER_OFF'};
  static const _laundryPause = {'PAUSE'};
  static const _laundryStop = {
    'POWER_OFF', 'INITIAL', 'END', 'SLEEP', 'ERROR', 'RESERVED', //
    'SMART_DIAGNOSIS', 'FIRMWARE', 'CANCEL', 'COMPLETE',
  };

  static const _vacuumStatus = {
    'CLEANING': 'cleaning',
    'MACROSECTOR': 'cleaning',
    'MONITORING_DETECTING': 'cleaning',
    'PAUSE': 'paused',
    'HOMING': 'returning',
    'CHARGING': 'charging',
    'CHARGING_COMPLETE': 'docked',
    'ERROR': 'error',
  };

  // ---------------------------------------------------------------- HTTP --
  /// 22-char base64url of a random (v4) UUID, like the SDK's `x-message-id`.
  String messageId() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    return base64Url.encode(b).substring(0, 22);
  }

  Future<Map<String, String>> headers({bool control = false}) async {
    final tok = (await token())?.trim();
    if (tok == null || tok.isEmpty) {
      throw const BackendException(503, 'LG ThinQ 토큰이 설정되지 않았습니다.');
    }
    return {
      'Authorization': 'Bearer $tok',
      'x-country': _country,
      'x-message-id': messageId(),
      'x-client-id': clientId,
      'x-api-key': _apiKey,
      'x-service-phase': 'OP',
      'Content-Type': 'application/json',
      if (control) 'x-conditional-control': 'true',
    };
  }

  /// Returns the envelope's `response` (may be a Map, List or null).
  Future<Object?> _request(String method, String path, {Object? body, bool control = false}) async {
    final url = Uri.parse('$baseUrl$path');
    final req = http.Request(method, url)..headers.addAll(await headers(control: control));
    if (body != null) req.body = jsonEncode(body);
    http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(timeout));
    } on TimeoutException {
      throw const BackendException(0, 'LG ThinQ 응답 시간이 초과되었습니다.');
    } catch (e) {
      throw BackendException(0, 'LG ThinQ에 연결할 수 없습니다: $e');
    }
    final text = utf8.decode(res.bodyBytes);
    Object? data;
    try {
      data = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      data = text.length > 300 ? text.substring(0, 300) : text;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return data is Map ? data['response'] : data;
    }
    final err = data is Map ? asMap(data['error']) : <String, dynamic>{};
    final code = '${err['code'] ?? ''}';
    final msg = err['message'] ?? data;
    if (code == '2301') {
      // COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF
      throw BackendException(403, "LG 기기의 원격 제어가 꺼져 있습니다. 기기에서 '원격 시작'을 켠 뒤 다시 시도하세요. ($code: $msg)");
    }
    if (res.statusCode == 401 || res.statusCode == 403 || const {'1103', '1218', '1302'}.contains(code)) {
      throw CloudAuthException(
        providerId,
        'LG ThinQ가 토큰을 거부했습니다. 토큰과 국가 설정을 확인하거나 새 토큰을 발급받으세요. '
        '(${res.statusCode}/$code: $msg)',
      );
    }
    if (res.statusCode == 429) {
      throw const BackendException(429, 'LG ThinQ 요청이 너무 많습니다. 잠시 후 다시 시도하세요.');
    }
    throw BackendException(502, 'LG ThinQ $method $path -> ${res.statusCode}/$code: $msg');
  }

  // ------------------------------------------------------------ discovery --
  @override
  Future<List<Device>> listDevices() async {
    final items = asList(await _request('GET', '/devices')).map(asMap).toList();
    final perItem = await Future.wait(
      items.map((item) async {
        final did = item['deviceId'] as String?;
        final dtype = '${asMap(item['deviceInfo'])['deviceType'] ?? ''}';
        Map<String, dynamic> profile = {};
        Object? state = <String, dynamic>{};
        if (_typeKind.containsKey(dtype)) {
          profile = await _tolerant(() async => asMap(await _request('GET', '/devices/$did/profile')), {});
          state = await _tolerant<Object?>(() => _request('GET', '/devices/$did/state'), <String, dynamic>{});
        }
        return devicesFromItem(item, profile, state);
      }),
    );
    return [for (final l in perItem) ...l];
  }

  /// Auth errors propagate; any other failure yields [fallback] (e.g. a
  /// device that is offline still gets listed).
  Future<T> _tolerant<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } on CloudAuthException {
      rethrow;
    } catch (_) {
      return fallback;
    }
  }

  /// Public for tests. A washer tower (multiple `location` blocks) yields one
  /// device per unit.
  List<Device> devicesFromItem(Map<String, dynamic> item, Map<String, dynamic> profile, Object? state) {
    final did = item['deviceId'] as String;
    final info = asMap(item['deviceInfo']);
    final dtype = '${info['deviceType'] ?? ''}';
    final alias = _firstNonEmpty([info['alias'], info['modelName']]) ?? did;
    final kind = _typeKind[dtype] ?? _typeKindPassive[dtype] ?? 'unknown';
    final baseMeta = <String, dynamic>{
      'cloudId': did,
      'source': 'cloud',
      'vendor': 'LG',
      'deviceType': dtype,
      'model': info['modelName'],
      'match': {'brand': 'LG', 'model': info['modelName'], 'name': alias, 'mac': null},
    };
    final prop = profile['property'];

    Device mk(String devId, String devName, Map<String, CapabilityInstance> caps, Map<String, dynamic> extra) => Device(
      id: devId,
      name: devName,
      adapter: providerId,
      kind: kind,
      reachable: true,
      controllable: caps.isNotEmpty,
      capabilities: caps,
      meta: {...baseMeta, ...extra},
    );

    if ((kind == 'washer' || kind == 'dryer') && _typeKind.containsKey(dtype)) {
      final key = kind == 'washer' ? 'washer' : 'dryer';
      var states = _locBlocks(state);
      final profiles = {for (final (loc, blk) in _locBlocks(prop)) loc: blk};
      if (states.isEmpty) {
        states = profiles.isNotEmpty ? [for (final loc in profiles.keys) (loc, <String, dynamic>{})] : [(null, {})];
      }
      final multi = states.length > 1;
      return [
        for (final (loc, st) in states)
          mk(
            '$providerId:$did${multi && loc != null ? ':$loc' : ''}',
            alias + (multi && loc != null ? ' ($loc)' : ''),
            {key: _laundryCap(key, kind, st, profiles[loc] ?? profiles[null] ?? <String, dynamic>{})},
            {'location': loc},
          ),
      ];
    }

    if (kind == 'refrigerator' && _typeKind.containsKey(dtype)) {
      return [
        mk('$providerId:$did', alias, {'refrigeration': _fridgeCap(asMap(state), asMap(prop))}, {}),
      ];
    }

    if (kind == 'vacuum') {
      final (inst, extra) = _vacuumCap(asMap(state), asMap(prop));
      return [
        mk('$providerId:$did', alias, {'vacuum': inst}, extra),
      ];
    }

    // Unmapped LG device type: show it, but not controllable.
    return [mk('$providerId:$did', alias, {}, {})];
  }

  static String? _firstNonEmpty(List<Object?> xs) {
    for (final x in xs) {
      if (x is String && x.isNotEmpty) return x;
    }
    return null;
  }

  /// Normalizes profile/state layouts: a Map (single unit) or a List of
  /// per-location Maps (`{"location": {"locationName": "MAIN"}, ...}`).
  static List<(String?, Map<String, dynamic>)> _locBlocks(Object? section) {
    if (section is Map) return [(null, Map<String, dynamic>.from(section))];
    return [
      if (section is List)
        for (final blk in section)
          if (blk is Map) (asMap(blk['location'])['locationName'] as String?, Map<String, dynamic>.from(blk)),
    ];
  }

  /// Profile property -> writable enum values; `[]` if read-only; `null` if the
  /// property isn't described at all.
  static List<Object?>? _writableValues(Object? prop) {
    if (prop is! Map) return prop == null ? null : <Object?>[];
    if (!asList(prop['mode']).contains('w')) return <Object?>[];
    final w = asMap(prop['value'])['w'];
    return w is List ? List<Object?>.of(w) : <Object?>[true];
  }

  // ---------------------------------------------------------- mapping ----
  static CapabilityInstance _laundryCap(String key, String kind, Map<String, dynamic> st, Map<String, dynamic> pblk) {
    final modeKey = kind == 'washer' ? 'washerOperationMode' : 'dryerOperationMode';
    final curRaw = '${asMap(st['runState'])['currentState'] ?? ''}'.toUpperCase();
    final String? cur = curRaw.isEmpty ? null : curRaw;
    final String machine;
    if (cur != null && _laundryPause.contains(cur)) {
      machine = 'pause';
    } else if (cur == null || _laundryStop.contains(cur)) {
      machine = 'stop';
    } else {
      machine = 'run';
    }
    final timer = asMap(st['timer']);
    int? remaining;
    if (timer.containsKey('remainHour') || timer.containsKey('remainMinute')) {
      remaining = _toInt(timer['remainHour']) * 60 + _toInt(timer['remainMinute']);
    }
    final rc = asMap(st['remoteControlEnable'])['remoteControlEnabled'];
    final writable = _writableValues(asMap(asMap(pblk['operation']))[modeKey]);
    final actions = writable == null
        ? _laundryActionValue.keys.toList()
        : [
            for (final e in _laundryActionValue.entries)
              if (writable.contains(e.value)) e.key,
          ];
    return CapabilityInstance(
      key: key,
      actions: actions,
      state: {
        'machineState': machine,
        'jobState': cur?.toLowerCase(),
        'remainingMinutes': remaining,
        'completionTime': null,
        'remoteControlEnabled': rc is bool ? rc : null,
      },
    );
  }

  static int _toInt(Object? v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

  static CapabilityInstance _fridgeCap(Map<String, dynamic> st, Map<String, dynamic> prop) {
    final state = <String, dynamic>{
      'unit': null,
      // ThinQ Connect publishes target temperatures only (no measured value).
      'fridgeTemperature': null,
      'freezerTemperature': null,
      'fridgeSetpoint': null,
      'freezerSetpoint': null,
      'doors': <String, bool>{},
      'doorOpen': null,
      'rapidCooling': null,
      'rapidFreezing': null,
    };
    final tempBlocks = asList(st['temperatureInUnits']).isNotEmpty ? st['temperatureInUnits'] : st['temperature'];
    for (final blk in asList(tempBlocks).map(asMap)) {
      final loc = '${blk['locationName'] ?? ''}'.toUpperCase();
      final unit = '${blk['unit'] ?? 'C'}'.toUpperCase();
      final v = blk.containsKey('targetTemperature$unit') ? blk['targetTemperature$unit'] : blk['targetTemperature'];
      state['unit'] ??= unit;
      if (loc == 'FRIDGE') {
        state['fridgeSetpoint'] = v;
      } else if (loc == 'FREEZER') {
        state['freezerSetpoint'] = v;
      }
    }
    final doors = state['doors'] as Map<String, bool>;
    for (final blk in asList(st['doorStatus']).map(asMap)) {
      final loc = '${blk['locationName'] ?? 'MAIN'}'.toLowerCase();
      if (blk['doorState'] != null) doors[loc] = '${blk['doorState']}'.toUpperCase() == 'OPEN';
    }
    state['doorOpen'] = doors.isNotEmpty ? doors.values.any((v) => v) : null;
    final refr = asMap(st['refrigeration']);
    final rf = refr.containsKey('rapidFreeze') ? refr['rapidFreeze'] : refr['expressMode'];
    state['rapidFreezing'] = rf is bool ? rf : null;
    final rc = refr['expressFridge'];
    state['rapidCooling'] = rc is bool ? rc : null;
    state['unit'] ??= 'C';

    final actions = <String>[];
    final ptemps = {
      for (final b in asList(prop['temperatureInUnits']).map(asMap)) '${b['locationName'] ?? ''}'.toUpperCase(): b,
    };
    for (final (loc, action, skey) in const [
      ('FRIDGE', 'setFridgeSetpoint', 'fridgeSetpoint'),
      ('FREEZER', 'setFreezerSetpoint', 'freezerSetpoint'),
    ]) {
      final pb = ptemps[loc];
      if (pb != null) {
        final writable = pb.entries.any(
          (e) => e.key.startsWith('targetTemperature') && (_writableValues(e.value) ?? const []).isNotEmpty,
        );
        if (writable) actions.add(action);
      } else if (ptemps.isEmpty && state[skey] != null) {
        actions.add(action);
      }
    }
    final prefr = asMap(prop['refrigeration']);
    if (prefr.isNotEmpty) {
      if ((_writableValues(prefr['expressFridge']) ?? const []).isNotEmpty) actions.add('setRapidCooling');
      if ((_writableValues(prefr['rapidFreeze']) ?? const []).isNotEmpty ||
          (_writableValues(prefr['expressMode']) ?? const []).isNotEmpty) {
        actions.add('setRapidFreezing');
      }
    } else {
      if (state['rapidCooling'] != null) actions.add('setRapidCooling');
      if (state['rapidFreezing'] != null) actions.add('setRapidFreezing');
    }
    return CapabilityInstance(key: 'refrigeration', actions: actions, state: state);
  }

  static (CapabilityInstance, Map<String, dynamic>) _vacuumCap(Map<String, dynamic> st, Map<String, dynamic> prop) {
    final cur = '${asMap(st['runState'])['currentState'] ?? ''}'.toUpperCase();
    final pct = asMap(st['battery'])['percent'];
    final job = asMap(st['robotCleanerJobMode'])['currentJobMode'];
    final jobProp = asMap(prop['robotCleanerJobMode'])['currentJobMode'];
    final modes = jobProp is Map ? asMap(jobProp['value'])['r'] : null;
    final writable = _writableValues(asMap(prop['operation'])['cleanOperationMode']);
    // ASSUMPTION (as on the hub): cleanOperationMode START/PAUSE/HOMING/RESUME/WAKE_UP.
    final actions = writable == null
        ? ['start', 'pause', 'dock']
        : [
            for (final (a, v) in const [('start', 'START'), ('pause', 'PAUSE'), ('dock', 'HOMING')])
              if (writable.contains(v)) a,
          ];
    final inst = CapabilityInstance(
      key: 'vacuum',
      actions: actions,
      state: {
        'status': _vacuumStatus[cur] ?? 'idle',
        'battery': pct is int ? pct : null,
        'cleaningMode': job,
        'cleaningModes': asList(modes).map((e) => '$e').toList(),
      },
    );
    // Vendor details needed for START vs RESUME/WAKE_UP; kept out of canonical state.
    return (inst, {'lgRunState': cur.isEmpty ? null : cur, 'lgCleanOperationWritable': writable});
  }

  // ----------------------------------------------------------- control ---
  @override
  Future<Map<String, dynamic>> execute(
    Device device,
    String capability,
    String action,
    Map<String, dynamic> params,
  ) async {
    validateAction(capability, action);
    final did = device.meta['cloudId'] as String;
    final loc = device.meta['location'] as String?;

    if (capability == 'washer' || capability == 'dryer') {
      final modeKey = capability == 'washer' ? 'washerOperationMode' : 'dryerOperationMode';
      if (action == 'start') {
        final live = await _request('GET', '/devices/$did/state');
        final blocks = {for (final (l, b) in _locBlocks(live)) l: b};
        final st = blocks[loc] ?? blocks[null] ?? (blocks.isNotEmpty ? blocks.values.first : <String, dynamic>{});
        final flag = asMap(st['remoteControlEnable'])['remoteControlEnabled'];
        requireRemoteStart(flag is bool ? flag : null, device);
      }
      final payload = <String, dynamic>{
        if (loc != null) 'location': {'locationName': loc},
        'operation': {modeKey: _laundryActionValue[action]},
      };
      return _control(did, payload);
    }

    if (capability == 'refrigeration') {
      if (action == 'setFridgeSetpoint' || action == 'setFreezerSetpoint') {
        final t = numParam(params, 'temperature');
        final inst = device.capabilities['refrigeration'];
        final unit = '${params['unit'] ?? inst?.state['unit'] ?? 'C'}'.toUpperCase();
        final where = action == 'setFridgeSetpoint' ? 'FRIDGE' : 'FREEZER';
        return _control(did, {
          'temperatureInUnits': {'locationName': where, 'targetTemperature$unit': t},
        });
      }
      final enabled = params['enabled'];
      if (enabled is! bool) throw const BackendException(400, "'enabled' must be true or false");
      // ASSUMPTION (as on the hub): expressFridge = "Express Cool", rapidFreeze = "Express Freeze".
      if (action == 'setRapidCooling') {
        return _control(did, {
          'refrigeration': {'expressFridge': enabled},
        });
      }
      return _control(did, {
        'refrigeration': {'rapidFreeze': enabled},
      });
    }

    if (capability == 'vacuum') {
      final status = device.capabilities['vacuum']?.state['status'];
      final runState = '${device.meta['lgRunState'] ?? ''}'.toUpperCase();
      final writable = asList(device.meta['lgCleanOperationWritable']);
      var value = const {'start': 'START', 'pause': 'PAUSE', 'dock': 'HOMING'}[action];
      if (value == null) throw BackendException(400, 'LG robot cleaners do not support vacuum.$action');
      if (action == 'start') {
        if (runState == 'SLEEP' && writable.contains('WAKE_UP')) {
          value = 'WAKE_UP';
        } else if (status == 'paused' && writable.contains('RESUME')) {
          value = 'RESUME';
        }
      }
      return _control(did, {
        'operation': {'cleanOperationMode': value},
      });
    }

    throw BackendException(400, 'unsupported: $capability.$action');
  }

  Future<Map<String, dynamic>> _control(String did, Map<String, dynamic> payload) async {
    final resp = await _request('POST', '/devices/$did/control', body: payload, control: true);
    return {'ok': true, 'method': 'lg_thinq', 'payload': payload, 'response': resp};
  }

  // ----------------------------------------------------------- refresh ---
  @override
  Future<Device> refresh(Device device) async {
    final did = device.meta['cloudId'] as String;
    final item = {
      'deviceId': did,
      'deviceInfo': {'deviceType': device.meta['deviceType'], 'alias': device.name, 'modelName': device.meta['model']},
    };
    final profile = asMap(await _request('GET', '/devices/$did/profile'));
    final state = await _request('GET', '/devices/$did/state') ?? <String, dynamic>{};
    for (final fresh in devicesFromItem(item, profile, state)) {
      if (fresh.id == device.id || fresh.meta['location'] == device.meta['location']) {
        final caps = {
          for (final e in device.capabilities.entries)
            e.key: fresh.capabilities.containsKey(e.key) ? fresh.capabilities[e.key]! : e.value,
        };
        final meta = {...device.meta};
        for (final k in const ['lgRunState', 'lgCleanOperationWritable']) {
          if (fresh.meta.containsKey(k)) meta[k] = fresh.meta[k];
        }
        return device.copyWith(capabilities: caps, meta: meta, reachable: true);
      }
    }
    return device.copyWith(reachable: true);
  }

  @override
  void close() => _http.close();
}
