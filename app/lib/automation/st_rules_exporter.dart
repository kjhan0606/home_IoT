import '../models/automation.dart';
import '../models/device.dart';
import 'engine.dart';

/// Compiles a brand-neutral [Rule] into a SmartThings Rules API document
/// (`POST https://api.smartthings.com/v1/rules?locationId=...`), so the automation keeps running in
/// Samsung's cloud (or locally on a Samsung hub) with **no server of ours and the app closed**.
///
/// Only SmartThings devices can be targeted (they carry `meta.cloudId`). Anything that cannot be
/// expressed faithfully throws [StRuleUnsupported] with a Korean reason; the caller then keeps the
/// rule in the app/hub engine instead. UNVERIFIED against a real Samsung account: the JSON follows
/// the public Rules API reference/SDK types, see docs/home-automation.md.
class StRuleUnsupported implements Exception {
  const StRuleUnsupported(this.message);
  final String message;
  @override
  String toString() => message;
}

class StRuleExport {
  const StRuleExport(this.json, this.notes);
  final Map<String, dynamic> json;

  /// Human-readable caveats, e.g. "시간대는 위치 설정을 따릅니다".
  final List<String> notes;
}

const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']; // ISO 1..7

Map<String, dynamic> _midnightPlus(int minutes, {String? tz}) => {
  'time': {
    'reference': 'Midnight',
    'offset': {
      'value': {'integer': minutes},
      'unit': 'Minute',
    },
    'timeZoneId': ?tz,
  },
};

Map<String, dynamic> _deviceOperand(List<String> ids, String capability, String attribute, {String? trigger}) => {
  'device': {
    'devices': ids,
    'component': 'main',
    'capability': capability,
    'attribute': attribute,
    'trigger': ?trigger,
  },
};

bool _isSt(Device d) => d.adapter == 'smartthings' && d.meta['cloudId'] is String;

/// (component, stCapability, command, typed arguments) for a canonical command, or null if unsupported.
(String, String, String, List<Map<String, dynamic>>)? stCommand(
  Device d,
  String capability,
  String action,
  Map<String, dynamic> params,
) {
  final comps = d.meta['components'] is Map ? d.meta['components'] as Map : const {};
  final comp = (comps[capability] as String?) ?? 'main';
  final st = d.meta['stCapabilities'] is Map ? (d.meta['stCapabilities'] as Map)['main'] : null;
  final stCaps = st is List ? st.map((e) => '$e').toSet() : <String>{};
  switch (capability) {
    case 'power':
      if (action != 'turnOn' && action != 'turnOff') return null; // toggle is not deterministic
      final stCap = (comps['power.st'] as String?) ?? 'switch';
      return (comp, stCap, action == 'turnOn' ? 'on' : 'off', const []);
    case 'curtain':
      if (action == 'setPosition') {
        final p = params['position'];
        return p is num
            ? (
                comp,
                'windowShadeLevel',
                'setShadeLevel',
                [
                  {'integer': p.toInt()},
                ],
              )
            : null;
      }
      if ((action == 'open' || action == 'close') &&
          !stCaps.contains('windowShade') &&
          stCaps.contains('windowShadeLevel')) {
        return (
          comp,
          'windowShadeLevel',
          'setShadeLevel',
          [
            {'integer': action == 'open' ? 100 : 0},
          ],
        );
      }
      final cmd = const {'open': 'open', 'close': 'close', 'stop': 'pause'}[action];
      return cmd == null ? null : (comp, 'windowShade', cmd, const []);
    case 'lock':
      return action == 'lock' || action == 'unlock' ? (comp, 'lock', action, const []) : null;
    case 'brightness':
      final p = params['level'];
      return action == 'setLevel' && p is num
          ? (
              comp,
              'switchLevel',
              'setLevel',
              [
                {'integer': p.toInt()},
              ],
            )
          : null;
  }
  return null;
}

/// [devices]: the current device list (selectors are resolved *now*; a device added later is not
/// picked up by an already-registered Samsung rule -- re-register after adding devices).
StRuleExport buildStRule(Rule rule, List<Device> devices, {String? timeZoneId}) {
  final notes = <String>[];
  final st = devices.where(_isSt).toList();
  final t = rule.trigger;
  if (t.type == TriggerType.event) {
    throw const StRuleUnsupported("'외출/도착/기상 신호' 규칙은 Samsung 클라우드에서 실행할 수 없습니다(신호를 보낼 곳이 없음).");
  }
  if (t.type == TriggerType.deviceState) {
    final sc = t.state!;
    if (!(sc.capability == 'power' && sc.field == 'switch') && !(sc.capability == 'lock' && sc.field == 'locked')) {
      throw const StRuleUnsupported('이 기기 상태 조건은 Samsung 규칙으로 옮길 수 없습니다.');
    }
  }

  // ---- actions ---------------------------------------------------------
  final actions = <Map<String, dynamic>>[];
  for (final a in rule.actions) {
    final byCommand =
        <String, ({String comp, String cap, String cmd, List<Map<String, dynamic>> args, List<String> ids})>{};
    for (final d in st) {
      if (!d.controllable || !a.selector.matches(d)) continue;
      final inst = d.cap(a.capability);
      if (inst == null || !inst.actions.contains(a.action)) continue;
      final c = stCommand(d, a.capability, a.action, a.params);
      if (c == null) throw StRuleUnsupported('${a.capability}.${a.action} 동작은 Samsung 규칙으로 옮길 수 없습니다.');
      final key = '${c.$1}|${c.$2}|${c.$3}|${c.$4}';
      final g = byCommand[key];
      if (g == null) {
        byCommand[key] = (comp: c.$1, cap: c.$2, cmd: c.$3, args: c.$4, ids: [d.meta['cloudId'] as String]);
      } else {
        g.ids.add(d.meta['cloudId'] as String);
      }
    }
    for (final g in byCommand.values) {
      actions.add({
        'command': {
          'devices': g.ids,
          'commands': [
            {'component': g.comp, 'capability': g.cap, 'command': g.cmd, 'arguments': g.args},
          ],
        },
      });
    }
  }
  if (actions.isEmpty) throw const StRuleUnsupported('동작을 실행할 SmartThings 기기가 없습니다.');

  // ---- conditions ------------------------------------------------------
  final conds = <Map<String, dynamic>>[];
  for (final c in rule.conditions) {
    switch (c.type) {
      case ConditionType.timeWindow:
        final s = parseHhmm(c.start!), e = parseHhmm(c.end!);
        Map<String, dynamic> between(int a, int b) => {
          'between': {
            'value': {
              'time': {'reference': 'Now', 'timeZoneId': ?timeZoneId},
            },
            'start': _midnightPlus(a, tz: timeZoneId),
            'end': _midnightPlus(b, tz: timeZoneId),
          },
        };
        if (s == e) break;
        conds.add(
          s < e
              ? between(s, e)
              : {
                  'or': [between(s, 1440), between(0, e)],
                },
        );
      case ConditionType.days:
        throw const StRuleUnsupported("'요일' 조건은 시간 규칙의 요일 설정으로만 옮길 수 있습니다.");
      case ConditionType.allLightsOff:
      case ConditionType.anyLightOn:
      case ConditionType.deviceState:
        throw const StRuleUnsupported('이 추가 조건은 Samsung 규칙으로 옮길 수 없습니다.');
    }
  }

  // ---- trigger ---------------------------------------------------------
  Map<String, dynamic> action;
  switch (t.type) {
    case TriggerType.time:
      final min = parseHhmm(t.at!);
      Map<String, dynamic> specific = {
        'reference': 'Midnight',
        'offset': {
          'value': {'integer': min},
          'unit': 'Minute',
        },
        if (t.days.isNotEmpty) 'daysOfWeek': [for (final d in t.days) _dayNames[d - 1]],
        'timeZoneId': ?timeZoneId,
      };
      if (timeZoneId == null) notes.add('시간대는 SmartThings 위치 설정을 따릅니다.');
      final inner = conds.isEmpty
          ? actions
          : [
              {
                'if': {if (conds.length == 1) ...conds.single else 'and': conds, 'then': actions},
              },
            ];
      action = {
        'every': {'specific': specific, 'actions': inner},
      };
    case TriggerType.allLightsOff:
      final lights = [
        for (final d in st)
          if (isLight(d)) d.meta['cloudId'] as String,
      ];
      if (lights.isEmpty) throw const StRuleUnsupported('SmartThings 조명이 없어 규칙을 만들 수 없습니다.');
      final allOff = {
        'changes': {
          'equals': {
            'left': _deviceOperand(lights, 'switch', 'switch', trigger: 'Always'),
            'right': {'string': 'off'},
            'aggregation': 'All',
          },
        },
      };
      notes.add('조명 ${lights.length}개를 기준으로 합니다. 조명을 추가하면 규칙을 다시 등록하세요.');
      action = {
        'if': {
          if (conds.isEmpty) ...allOff else 'and': [allOff, ...conds],
          'then': actions,
        },
      };
    case TriggerType.deviceState:
      final sc = t.state!;
      final ids = [
        for (final d in st)
          if (sc.selector.matches(d) && d.has(sc.capability)) d.meta['cloudId'] as String,
      ];
      if (ids.isEmpty) throw const StRuleUnsupported('조건에 맞는 SmartThings 기기가 없습니다.');
      final (stCap, attr, value) = sc.capability == 'power'
          ? ('switch', 'switch', '${sc.equals}')
          : ('lock', 'lock', sc.equals == true ? 'locked' : 'unlocked');
      final eq = {
        'changes': {
          'equals': {
            'left': _deviceOperand(ids, stCap, attr, trigger: 'Always'),
            'right': {'string': value},
            'aggregation': sc.match == 'all' ? 'All' : 'Any',
          },
        },
      };
      action = {
        'if': {
          if (conds.isEmpty) ...eq else 'and': [eq, ...conds],
          'then': actions,
        },
      };
    case TriggerType.event:
      throw StateError('handled above');
  }

  return StRuleExport({
    'name': rule.name.length > 100 ? rule.name.substring(0, 100) : rule.name,
    'actions': [action],
    'timeZoneId': ?timeZoneId,
  }, notes);
}
