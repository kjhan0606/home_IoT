import '../models/automation.dart';
import '../models/device.dart';

/// Pure rule evaluation (no I/O, no clock, no timers). Line-for-line port of
/// `hub/homehub/automation/engine.py`; both run the shared scenarios in
/// `test/fixtures/automation_scenarios.json` so they cannot drift apart.

/// A time trigger still fires up to this many minutes late (tick jitter, app opened a bit late).
const timeGraceMinutes = 10;

class Step {
  const Step({
    required this.deviceId,
    required this.deviceName,
    required this.capability,
    required this.action,
    this.params = const {},
    this.skip,
  });

  final String deviceId, deviceName, capability, action;
  final Map<String, dynamic> params;
  final String? skip;
}

class Fire {
  const Fire({required this.ruleId, required this.ruleName, required this.reason, this.key, this.steps = const []});

  final String ruleId, ruleName, reason;
  final String? key; // last-fired key for time triggers (de-duplication)
  final List<Step> steps;
}

bool isLight(Device d) => d.kind == 'light' && d.has('power');

bool lightIsOn(Device d) => d.cap('power')!.state['switch'] == 'on';

/// Controllable, reachable lights (an offline bulb must not block "all lights off").
List<Device> lightsOf(Iterable<Device> devices) => [
  for (final d in devices)
    if (isLight(d) && d.reachable) d,
];

/// true/false, or null when the home has no (reachable) light at all.
bool? allLightsOff(Iterable<Device> devices) {
  final ls = lightsOf(devices);
  return ls.isEmpty ? null : !ls.any(lightIsOn);
}

/// Minutes after midnight for "HH:MM".
int parseHhmm(String v) {
  final m = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(v);
  if (m == null) throw FormatException("time must be 'HH:MM', got '$v'");
  return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
}

/// [start, end) on a 24 h clock; a window with start > end crosses midnight.
bool inWindow(int nowMin, int start, int end) {
  if (start == end) return true;
  return start < end ? (start <= nowMin && nowMin < end) : (nowMin >= start || nowMin < end);
}

bool _stateTrue(Iterable<Device> devices, StateCheck chk) {
  final hits = [
    for (final d in devices)
      if (chk.selector.matches(d) && d.has(chk.capability) && d.reachable) d,
  ];
  if (hits.isEmpty) return false;
  bool eq(Device d) => d.cap(chk.capability)!.state[chk.field] == chk.equals;
  return chk.match == 'all' ? hits.every(eq) : hits.any(eq);
}

bool _conditionOk(Condition c, List<Device> devices, DateTime now) {
  switch (c.type) {
    case ConditionType.timeWindow:
      return inWindow(now.hour * 60 + now.minute, parseHhmm(c.start!), parseHhmm(c.end!));
    case ConditionType.days:
      return c.days.contains(now.weekday);
    case ConditionType.allLightsOff:
      return allLightsOff(devices) == true;
    case ConditionType.anyLightOn:
      return allLightsOff(devices) == false;
    case ConditionType.deviceState:
      return _stateTrue(devices, c.state!);
  }
}

/// Reason to skip a command that would change nothing (saves cloud calls).
String? alreadyState(Device d, String capability, String action, Map<String, dynamic> params) {
  final st = d.cap(capability)!.state;
  if (capability == 'power' && (action == 'turnOn' || action == 'turnOff')) {
    if (st['switch'] == (action == 'turnOn' ? 'on' : 'off')) return action == 'turnOn' ? 'already-on' : 'already-off';
  }
  if (capability == 'curtain') {
    final pos = st['position'], status = st['status'];
    if (action == 'close' && (status == 'closed' || pos == 0)) return 'already-closed';
    if (action == 'open' && (status == 'open' || pos == 100)) return 'already-open';
    if (action == 'setPosition' && pos != null && pos == params['position']) return 'already-there';
  }
  if (capability == 'lock' && (action == 'lock' || action == 'unlock')) {
    if (st['locked'] == (action == 'lock')) return action == 'lock' ? 'already-locked' : 'already-unlocked';
  }
  return null;
}

List<Step> _steps(Rule rule, List<Device> devices) {
  final steps = <Step>[];
  final sorted = [...devices]..sort((a, b) => a.id.compareTo(b.id));
  for (final a in rule.actions) {
    for (final d in sorted) {
      if (!(d.controllable && d.reachable && a.selector.matches(d))) continue;
      final inst = d.cap(a.capability);
      if (inst == null || !inst.actions.contains(a.action)) continue;
      steps.add(
        Step(
          deviceId: d.id,
          deviceName: d.name,
          capability: a.capability,
          action: a.action,
          params: Map<String, dynamic>.from(a.params),
          skip: alreadyState(d, a.capability, a.action, a.params),
        ),
      );
    }
  }
  return steps;
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Key like '2026-09-29@07:00' while a time trigger is due (within the grace window).
String? timeKey(Rule rule, DateTime now) {
  final t = rule.trigger;
  if (t.type != TriggerType.time) return null;
  if (t.days.isNotEmpty && !t.days.contains(now.weekday)) return null;
  final late = now.hour * 60 + now.minute - parseHhmm(t.at!);
  if (late < 0 || late >= timeGraceMinutes) return null;
  return '${now.year.toString().padLeft(4, '0')}-${_two(now.month)}-${_two(now.day)}@${t.at}';
}

/// Rules that fire between the [prev] and [cur] snapshots ([prev] null = first look:
/// state-change triggers cannot fire because there is no earlier state to compare with).
List<Fire> evaluate({
  required List<Rule> rules,
  required Map<String, Device>? prev,
  required Map<String, Device> cur,
  required DateTime now,
  Iterable<String> events = const [],
  Map<String, String> lastFired = const {},
}) {
  final evs = events.toSet();
  final curList = cur.values.toList();
  final prevList = prev?.values.toList();
  final out = <Fire>[];
  for (final rule in rules) {
    if (!rule.enabled) continue;
    final t = rule.trigger;
    String? reason, key;
    switch (t.type) {
      case TriggerType.time:
        key = timeKey(rule, now);
        if (key != null && lastFired[rule.id] != key) {
          reason = '시간 ${t.at}';
        } else {
          key = null;
        }
      case TriggerType.event:
        if (evs.contains(t.name)) reason = '이벤트 ${t.name}';
      case TriggerType.allLightsOff:
        if (prevList != null && allLightsOff(prevList) == false && allLightsOff(curList) == true) {
          reason = '모든 조명이 꺼짐';
        }
      case TriggerType.deviceState:
        if (prevList != null && !_stateTrue(prevList, t.state!) && _stateTrue(curList, t.state!)) {
          reason = '${t.state!.capability}.${t.state!.field} = ${t.state!.equals}';
        }
    }
    if (reason == null) continue;
    if (!rule.conditions.every((c) => _conditionOk(c, curList, now))) continue;
    out.add(Fire(ruleId: rule.id, ruleName: rule.name, reason: reason, key: key, steps: _steps(rule, curList)));
  }
  return out;
}
