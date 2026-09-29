import '../models/automation.dart';
import '../models/device.dart';
import 'engine.dart' show isLight;

/// Ready-made rules for non-technical users. A template only needs the user to confirm a time or
/// two; everything else is fixed. [available] says whether the home has the devices it needs.
class RuleTemplate {
  const RuleTemplate({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.build,
    required this.available,
    this.needsTime = false,
    this.needsWindow = false,
    this.defaultTime = '07:00',
    this.hint,
  });

  final String id, title, description;
  final String icon; // key mapped to an IconData in the UI
  final bool needsTime; // asks for a wake-up style time
  final bool needsWindow; // asks for a bedtime window
  final String defaultTime;
  final String? hint;

  /// Builds the rule. [time] = "HH:MM", [windowStart]/[windowEnd] = "HH:MM".
  final Rule Function(String id, {String time, String windowStart, String windowEnd}) build;

  /// Whether the given devices support this template (e.g. curtains exist).
  final bool Function(List<Device> devices) available;
}

String newRuleId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

bool _has(List<Device> ds, String cap) => ds.any((d) => d.controllable && d.has(cap));

const _closeCurtains = RuleAction(
  selector: Selector(capability: 'curtain'),
  capability: 'curtain',
  action: 'close',
);
const _openCurtains = RuleAction(
  selector: Selector(capability: 'curtain'),
  capability: 'curtain',
  action: 'open',
);
const _lightsOff = RuleAction(
  selector: Selector(kind: 'light'),
  capability: 'power',
  action: 'turnOff',
);
const _lockAll = RuleAction(
  selector: Selector(capability: 'lock'),
  capability: 'lock',
  action: 'lock',
);

final ruleTemplates = <RuleTemplate>[
  RuleTemplate(
    id: 'bedtime-close-curtains',
    title: '취침 시 커튼 닫기',
    description: '취침 시간대에 모든 조명이 꺼지면 커튼을 닫습니다.',
    icon: 'bedtime',
    needsWindow: true,
    hint: '조명이 하나라도 켜져 있다가 모두 꺼지는 순간, 이 시간대 안이면 실행됩니다.',
    available: (ds) => _has(ds, 'curtain') && ds.any(isLight),
    build: (id, {time = '07:00', windowStart = '22:00', windowEnd = '02:00'}) => Rule(
      id: id,
      name: '취침 시 커튼 닫기',
      template: 'bedtime-close-curtains',
      trigger: const Trigger.allLightsOff(),
      conditions: [Condition.timeWindow(windowStart, windowEnd)],
      actions: const [_closeCurtains],
    ),
  ),
  RuleTemplate(
    id: 'wake-open-curtains',
    title: '기상 시 커튼 열기',
    description: '정해진 기상 시간에 커튼을 엽니다.',
    icon: 'wb_sunny',
    needsTime: true,
    defaultTime: '07:00',
    hint: '알람과 연동하려면 이 규칙 대신 "기상" 신호(단축어/허브)로 실행하도록 바꿀 수 있습니다.',
    available: (ds) => _has(ds, 'curtain'),
    build: (id, {time = '07:00', windowStart = '22:00', windowEnd = '02:00'}) => Rule(
      id: id,
      name: '기상 시 커튼 열기',
      template: 'wake-open-curtains',
      trigger: Trigger.time(time),
      actions: const [_openCurtains],
    ),
  ),
  RuleTemplate(
    id: 'wake-signal-open-curtains',
    title: '기상 신호로 커튼 열기',
    description: '"기상" 신호(휴대폰 알람 해제 단축어 등)를 받으면 커튼을 엽니다.',
    icon: 'alarm',
    hint: '신호 보내는 법: 앱의 자동화 화면 > 신호 보내기, 또는 허브 POST /automation/events/wake',
    available: (ds) => _has(ds, 'curtain'),
    build: (id, {time = '07:00', windowStart = '22:00', windowEnd = '02:00'}) => Rule(
      id: id,
      name: '기상 신호로 커튼 열기',
      template: 'wake-signal-open-curtains',
      trigger: const Trigger.event('wake'),
      actions: const [_openCurtains],
    ),
  ),
  RuleTemplate(
    id: 'leaving-lights-off',
    title: '외출 시 조명 끄기',
    description: '"외출" 신호를 받으면 모든 조명을 끕니다.',
    icon: 'logout',
    hint: '외출 신호는 앱의 자동화 화면에서 누르거나 휴대폰 단축어/허브로 보냅니다.',
    available: (ds) => ds.any(isLight),
    build: (id, {time = '07:00', windowStart = '22:00', windowEnd = '02:00'}) => Rule(
      id: id,
      name: '외출 시 조명 끄기',
      template: 'leaving-lights-off',
      trigger: const Trigger.event('leaving'),
      actions: const [_lightsOff],
    ),
  ),
  RuleTemplate(
    id: 'leaving-lock-door',
    title: '외출 시 도어락 잠그기',
    description: '"외출" 신호를 받으면 도어락을 잠급니다.',
    icon: 'lock',
    available: (ds) => _has(ds, 'lock'),
    build: (id, {time = '07:00', windowStart = '22:00', windowEnd = '02:00'}) => Rule(
      id: id,
      name: '외출 시 도어락 잠그기',
      template: 'leaving-lock-door',
      trigger: const Trigger.event('leaving'),
      actions: const [_lockAll],
    ),
  ),
  RuleTemplate(
    id: 'leaving-close-curtains',
    title: '외출 시 커튼 닫기',
    description: '"외출" 신호를 받으면 커튼을 닫습니다.',
    icon: 'logout',
    available: (ds) => _has(ds, 'curtain'),
    build: (id, {time = '07:00', windowStart = '22:00', windowEnd = '02:00'}) => Rule(
      id: id,
      name: '외출 시 커튼 닫기',
      template: 'leaving-close-curtains',
      trigger: const Trigger.event('leaving'),
      actions: const [_closeCurtains],
    ),
  ),
  RuleTemplate(
    id: 'arriving-lights-on',
    title: '귀가 시 거실 조명 켜기',
    description: '"귀가" 신호를 받으면 조명을 켭니다.',
    icon: 'login',
    available: (ds) => ds.any(isLight),
    build: (id, {time = '07:00', windowStart = '22:00', windowEnd = '02:00'}) => Rule(
      id: id,
      name: '귀가 시 조명 켜기',
      template: 'arriving-lights-on',
      trigger: const Trigger.event('arriving'),
      actions: const [
        RuleAction(
          selector: Selector(kind: 'light'),
          capability: 'power',
          action: 'turnOn',
        ),
      ],
    ),
  ),
];

RuleTemplate? templateById(String id) {
  for (final t in ruleTemplates) {
    if (t.id == id) return t;
  }
  return null;
}

/// Korean one-line description of a rule ("모든 조명이 꺼지면 · 22:00~02:00 사이 → 커튼 닫기").
String describeRule(Rule r) {
  final t = switch (r.trigger.type) {
    TriggerType.time => '${_days(r.trigger.days)}${r.trigger.at}에',
    TriggerType.allLightsOff => '모든 조명이 꺼지면',
    TriggerType.event => switch (r.trigger.name) {
      'leaving' => '외출하면',
      'arriving' => '귀가하면',
      'wake' => '기상 신호를 받으면',
      final n => '"$n" 신호를 받으면',
    },
    TriggerType.deviceState => '기기 상태가 ${r.trigger.state!.equals}이(가) 되면',
  };
  final c = [
    for (final c in r.conditions)
      switch (c.type) {
        ConditionType.timeWindow => '${c.start}~${c.end} 사이일 때',
        ConditionType.days => _days(c.days).trim(),
        ConditionType.allLightsOff => '모든 조명이 꺼져 있을 때',
        ConditionType.anyLightOn => '조명이 켜져 있을 때',
        ConditionType.deviceState => '기기 상태 조건',
      },
  ];
  final a = [for (final a in r.actions) describeAction(a)];
  return '${[t, ...c].join(' · ')} → ${a.join(', ')}';
}

String _days(List<int> days) {
  if (days.isEmpty || days.length == 7) return '';
  const n = ['월', '화', '수', '목', '금', '토', '일'];
  return '${days.map((d) => n[d - 1]).join('·')} ';
}

String describeAction(RuleAction a) {
  final target = switch ((a.selector.kind, a.selector.capability)) {
    (_, 'curtain') => '커튼',
    ('light', _) => '조명',
    (_, 'lock') => '도어락',
    ('vacuum', _) || (_, 'vacuum') => '로봇청소기',
    _ => a.selector.deviceId ?? '기기',
  };
  final what = switch ('${a.capability}.${a.action}') {
    'curtain.open' => '열기',
    'curtain.close' => '닫기',
    'curtain.stop' => '정지',
    'curtain.setPosition' => '${a.params['position']}%로 열기',
    'power.turnOn' => '켜기',
    'power.turnOff' => '끄기',
    'lock.lock' => '잠그기',
    'lock.unlock' => '열기',
    'vacuum.start' => '청소 시작',
    'vacuum.dock' => '충전대로',
    final o => o,
  };
  return '$target $what';
}
