import 'device.dart';

/// Brand-neutral automation rule (JSON-compatible 1:1 with the hub's
/// `hub/homehub/automation/rules.py`; see docs/home-automation.md).
///
/// Rules refer to canonical capabilities and device *kinds* only, never to a brand.
class Selector {
  const Selector({this.deviceId, this.kind, this.room, this.capability});

  final String? deviceId, kind, room, capability;

  bool get isEmpty => deviceId == null && kind == null && room == null && capability == null;

  bool matches(Device d) {
    if (deviceId != null && d.id != deviceId) return false;
    if (kind != null && d.kind != kind) return false;
    if (room != null && d.meta['room'] != room) return false;
    if (capability != null && !d.has(capability!)) return false;
    return true;
  }

  Map<String, dynamic> toJson() => {'deviceId': ?deviceId, 'kind': ?kind, 'room': ?room, 'capability': ?capability};

  factory Selector.fromJson(Object? j) {
    final m = j is Map ? j : const {};
    String? s(String k) => m[k] is String && (m[k] as String).isNotEmpty ? m[k] as String : null;
    return Selector(deviceId: s('deviceId'), kind: s('kind'), room: s('room'), capability: s('capability'));
  }
}

enum TriggerType { time, allLightsOff, deviceState, event }

/// "When ..." part. Only the fields of its [type] are used.
class Trigger {
  const Trigger.time(String this.at, {this.days = const []}) : type = TriggerType.time, name = null, state = null;
  const Trigger.allLightsOff() : type = TriggerType.allLightsOff, at = null, days = const [], name = null, state = null;
  const Trigger.event(String this.name) : type = TriggerType.event, at = null, days = const [], state = null;
  const Trigger.deviceState(StateCheck this.state)
    : type = TriggerType.deviceState,
      at = null,
      days = const [],
      name = null;

  final TriggerType type;
  final String? at; // "HH:MM"
  final List<int> days; // ISO weekdays, 1 = Monday; empty = every day
  final String? name; // event name
  final StateCheck? state;

  Map<String, dynamic> toJson() => switch (type) {
    TriggerType.time => {'type': 'time', 'at': at, 'days': days},
    TriggerType.allLightsOff => {'type': 'allLightsOff'},
    TriggerType.event => {'type': 'event', 'name': name},
    TriggerType.deviceState => {'type': 'deviceState', ...state!.toJson()},
  };

  factory Trigger.fromJson(Map<String, dynamic> j) => switch (j['type']) {
    'time' => Trigger.time(j['at'] as String, days: _days(j['days'])),
    'allLightsOff' => const Trigger.allLightsOff(),
    'event' => Trigger.event(j['name'] as String),
    'deviceState' => Trigger.deviceState(StateCheck.fromJson(j)),
    _ => throw FormatException('unknown trigger ${j['type']}'),
  };
}

List<int> _days(Object? v) => v is List ? v.whereType<num>().map((e) => e.toInt()).toList() : const [];

/// "capability.field == equals" on the devices a [selector] picks (`match`: any | all).
class StateCheck {
  const StateCheck({
    required this.capability,
    required this.field,
    required this.equals,
    this.match = 'any',
    this.selector = const Selector(),
  });

  final String capability, field, match;
  final Object? equals;
  final Selector selector;

  Map<String, dynamic> toJson() => {
    'capability': capability,
    'field': field,
    'equals': equals,
    'match': match,
    'selector': selector.toJson(),
  };

  factory StateCheck.fromJson(Map<String, dynamic> j) => StateCheck(
    capability: j['capability'] as String,
    field: j['field'] as String,
    equals: j['equals'],
    match: (j['match'] as String?) ?? 'any',
    selector: Selector.fromJson(j['selector']),
  );
}

enum ConditionType { timeWindow, days, allLightsOff, anyLightOn, deviceState }

/// "Only if ..." part (all conditions must hold when the trigger fires).
class Condition {
  const Condition.timeWindow(String this.start, String this.end)
    : type = ConditionType.timeWindow,
      days = const [],
      state = null;
  const Condition.days(this.days) : type = ConditionType.days, start = null, end = null, state = null;
  const Condition.allLightsOff()
    : type = ConditionType.allLightsOff,
      start = null,
      end = null,
      days = const [],
      state = null;
  const Condition.anyLightOn()
    : type = ConditionType.anyLightOn,
      start = null,
      end = null,
      days = const [],
      state = null;
  const Condition.deviceState(StateCheck this.state)
    : type = ConditionType.deviceState,
      start = null,
      end = null,
      days = const [];

  final ConditionType type;
  final String? start, end;
  final List<int> days;
  final StateCheck? state;

  Map<String, dynamic> toJson() => switch (type) {
    ConditionType.timeWindow => {'type': 'timeWindow', 'start': start, 'end': end},
    ConditionType.days => {'type': 'days', 'days': days},
    ConditionType.allLightsOff => {'type': 'allLightsOff'},
    ConditionType.anyLightOn => {'type': 'anyLightOn'},
    ConditionType.deviceState => {'type': 'deviceState', ...state!.toJson()},
  };

  factory Condition.fromJson(Map<String, dynamic> j) => switch (j['type']) {
    'timeWindow' => Condition.timeWindow(j['start'] as String, j['end'] as String),
    'days' => Condition.days(_days(j['days'])),
    'allLightsOff' => const Condition.allLightsOff(),
    'anyLightOn' => const Condition.anyLightOn(),
    'deviceState' => Condition.deviceState(StateCheck.fromJson(j)),
    _ => throw FormatException('unknown condition ${j['type']}'),
  };
}

/// "Then ..." part: a canonical command sent to every device the selector matches
/// (that supports it).
class RuleAction {
  const RuleAction({
    this.selector = const Selector(),
    required this.capability,
    required this.action,
    this.params = const {},
  });

  final Selector selector;
  final String capability, action;
  final Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {
    'selector': selector.toJson(),
    'capability': capability,
    'action': action,
    'params': params,
  };

  factory RuleAction.fromJson(Map<String, dynamic> j) => RuleAction(
    selector: Selector.fromJson(j['selector']),
    capability: j['capability'] as String,
    action: j['action'] as String,
    params: Map<String, dynamic>.from((j['params'] as Map?) ?? const {}),
  );
}

class Rule {
  const Rule({
    required this.id,
    required this.name,
    required this.trigger,
    required this.actions,
    this.conditions = const [],
    this.enabled = true,
    this.template,
  });

  final String id, name;
  final bool enabled;
  final String? template;
  final Trigger trigger;
  final List<Condition> conditions;
  final List<RuleAction> actions;

  Rule copyWith({
    String? id,
    String? name,
    bool? enabled,
    Trigger? trigger,
    List<Condition>? conditions,
    List<RuleAction>? actions,
  }) => Rule(
    id: id ?? this.id,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    template: template,
    trigger: trigger ?? this.trigger,
    conditions: conditions ?? this.conditions,
    actions: actions ?? this.actions,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'template': template,
    'trigger': trigger.toJson(),
    'conditions': [for (final c in conditions) c.toJson()],
    'actions': [for (final a in actions) a.toJson()],
  };

  factory Rule.fromJson(Map<String, dynamic> j) => Rule(
    id: j['id'] as String,
    name: j['name'] as String,
    enabled: j['enabled'] != false,
    template: j['template'] as String?,
    trigger: Trigger.fromJson(Map<String, dynamic>.from(j['trigger'] as Map)),
    conditions: [
      for (final c in (j['conditions'] as List?) ?? const []) Condition.fromJson(Map<String, dynamic>.from(c as Map)),
    ],
    actions: [
      for (final a in (j['actions'] as List?) ?? const []) RuleAction.fromJson(Map<String, dynamic>.from(a as Map)),
    ],
  );
}

/// One executed command of a run.
class RunStep {
  const RunStep({
    required this.deviceId,
    required this.deviceName,
    required this.capability,
    required this.action,
    this.params = const {},
    this.skip,
    this.ok = true,
    this.error,
  });

  final String deviceId, deviceName, capability, action;
  final Map<String, dynamic> params;
  final String? skip; // e.g. "already-closed": nothing had to be sent
  final bool ok;
  final String? error;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'capability': capability,
    'action': action,
    'params': params,
    'skip': skip,
    'ok': ok,
    'error': ?error,
  };

  factory RunStep.fromJson(Map<String, dynamic> j) => RunStep(
    deviceId: (j['deviceId'] ?? '') as String,
    deviceName: (j['deviceName'] ?? '') as String,
    capability: (j['capability'] ?? '') as String,
    action: (j['action'] ?? '') as String,
    params: Map<String, dynamic>.from((j['params'] as Map?) ?? const {}),
    skip: j['skip'] as String?,
    ok: j['ok'] != false,
    error: j['error'] as String?,
  );
}

/// Run-log entry. [status]: ok | partial | error | skipped | no-targets.
class RunLogEntry {
  const RunLogEntry({
    required this.time,
    required this.ruleId,
    required this.ruleName,
    required this.reason,
    required this.status,
    this.steps = const [],
    this.where = 'app',
  });

  final DateTime time;
  final String ruleId, ruleName, reason, status;
  final List<RunStep> steps;
  final String where; // 'app' | 'hub'

  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'ruleId': ruleId,
    'ruleName': ruleName,
    'reason': reason,
    'status': status,
    'steps': [for (final s in steps) s.toJson()],
  };

  factory RunLogEntry.fromJson(Map<String, dynamic> j, {String where = 'app'}) => RunLogEntry(
    time: DateTime.tryParse('${j['time']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
    ruleId: (j['ruleId'] ?? '') as String,
    ruleName: (j['ruleName'] ?? '') as String,
    reason: (j['reason'] ?? '') as String,
    status: (j['status'] ?? 'ok') as String,
    steps: [for (final s in (j['steps'] as List?) ?? const []) RunStep.fromJson(Map<String, dynamic>.from(s as Map))],
    where: where,
  );
}
