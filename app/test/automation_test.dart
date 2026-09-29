import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/api/hub_api.dart';
import 'package:homeiot/automation/automation_controller.dart';
import 'package:homeiot/automation/engine.dart';
import 'package:homeiot/automation/rule_store.dart';
import 'package:homeiot/automation/st_rules_exporter.dart';
import 'package:homeiot/automation/templates.dart';
import 'package:homeiot/models/automation.dart';
import 'package:homeiot/models/device.dart';
import 'package:homeiot/models/hub_config.dart';
import 'package:homeiot/state/hub_state.dart';
import 'package:homeiot/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_hub_api.dart';

Map<String, Device>? snap(Object? j) => j == null
    ? null
    : {for (final e in (j as Map).entries) e.key as String: Device.fromJson(Map<String, dynamic>.from(e.value as Map))};

Device dev(
  String id,
  String kind,
  String cap,
  List<String> actions,
  Map<String, dynamic> state, {
  String room = '침실',
}) => Device(
  id: id,
  name: id,
  kind: kind,
  controllable: true,
  reachable: true,
  meta: {'room': room},
  capabilities: {cap: CapabilityInstance(key: cap, actions: actions, state: state)},
);

Device light(String id, bool on) =>
    dev(id, 'light', 'power', ['turnOn', 'turnOff', 'toggle'], {'switch': on ? 'on' : 'off'});
Device curtain(String id, {String status = 'open', int pos = 100, String room = '침실'}) => dev(
  id,
  'curtain',
  'curtain',
  ['open', 'close', 'stop', 'setPosition'],
  {'position': pos, 'status': status},
  room: room,
);
Map<String, Device> m(List<Device> ds) => {for (final d in ds) d.id: d};

const bedtime = Rule(
  id: 'bed',
  name: '취침 시 커튼 닫기',
  trigger: Trigger.allLightsOff(),
  conditions: [Condition.timeWindow('22:00', '02:00')],
  actions: [
    RuleAction(
      selector: Selector(capability: 'curtain'),
      capability: 'curtain',
      action: 'close',
    ),
  ],
);

void main() {
  group('engine: shared scenarios (same file the hub pytest runs)', () {
    final scenarios =
        (jsonDecode(File('test/fixtures/automation_scenarios.json').readAsStringSync()) as Map)['scenarios'] as List;
    for (final s in scenarios) {
      test(s['name'] as String, () {
        final fires = evaluate(
          rules: [for (final r in s['rules'] as List) Rule.fromJson(Map<String, dynamic>.from(r as Map))],
          prev: snap(s['prev']),
          cur: snap(s['cur'])!,
          now: DateTime.parse(s['now'] as String),
          events: List<String>.from(s['events'] as List),
          lastFired: Map<String, String>.from(s['lastFired'] as Map),
        );
        final got = [
          for (final f in fires)
            {
              'ruleId': f.ruleId,
              'reason': f.reason,
              'key': f.key,
              'steps': [
                for (final x in f.steps) {'deviceId': x.deviceId, 'action': x.action, 'skip': x.skip},
              ],
            },
        ];
        expect(jsonEncode(got), jsonEncode(s['expect']));
      });
    }
  });

  test('rule JSON round trip keeps every field', () {
    for (final t in ruleTemplates) {
      final r = t.build('id1', time: '06:45', windowStart: '23:00', windowEnd: '03:00');
      expect(jsonEncode(Rule.fromJson(r.toJson()).toJson()), jsonEncode(r.toJson()), reason: t.id);
    }
  });

  test('describeRule reads naturally in Korean', () {
    expect(describeRule(bedtime), '모든 조명이 꺼지면 · 22:00~02:00 사이일 때 → 커튼 닫기');
    expect(describeRule(templateById('leaving-lights-off')!.build('x')), '외출하면 → 조명 끄기');
    expect(describeRule(templateById('wake-open-curtains')!.build('x', time: '06:30')), '06:30에 → 커튼 열기');
  });

  test('templates are only available when the needed devices exist', () {
    final none = <Device>[light('l1', true)];
    expect(templateById('bedtime-close-curtains')!.available(none), isFalse);
    expect(templateById('leaving-lights-off')!.available(none), isTrue);
    expect(templateById('bedtime-close-curtains')!.available([light('l1', true), curtain('c1')]), isTrue);
  });

  group('AutomationController (direct mode: rules run in the app)', () {
    late FakeHubApi api;
    late HubState hub;
    late AutomationController ctl;
    late DateTime clock;
    late List<(String, String, String)> sent;

    Future<void> setUpCtl({bool viaHub = false}) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      clock = DateTime(2026, 9, 29, 22, 30);
      api = FakeHubApi();
      hub = HubState(settings: SettingsStore(prefs), apiFactory: (_) => api, now: () => clock);
      ctl = AutomationController(hub: hub, store: RuleStore(prefs), now: () => clock, tick: const Duration(days: 1));
      sent = [];
      if (viaHub) await hub.connect(const HubConfig(host: 'h'));
    }

    tearDown(() => ctl.dispose());

    test('hub mode: rules live on the hub; the app only edits them and never runs them', () async {
      await setUpCtl(viaHub: true);
      expect(ctl.hubManaged, isTrue);
      await ctl.load();
      await ctl.save(bedtime);
      expect(api.calls, contains('save-rule'));
      expect(ctl.rules.single.name, '취침 시 커튼 닫기');
      await ctl.setEnabled('bed', false);
      expect(api.rules.single['enabled'], false);
      // devices change: nothing is executed locally
      final before = api.commands.length;
      await ctl.evaluateNow(snap({}), m([light('l1', false), curtain('c1')]));
      expect(api.commands.length, before);
      await ctl.fireEvent('leaving');
      expect(api.calls, contains('event:leaving'));
      await ctl.delete('bed');
      expect(api.rules, isEmpty);
    });

    test('direct mode: bedtime rule closes curtains once when the last light goes off', () async {
      await setUpCtl();
      expect(ctl.hubManaged, isFalse);
      await ctl.save(bedtime);
      hub.debugSetDevices([light('l1', true), curtain('c1'), curtain('c2', status: 'closed', pos: 0)]);
      hub.debugCommandHook = (id, cap, action, p) async => sent.add((id, cap, action));
      // lights go off
      final prev = hub.devicesById;
      hub.debugSetDevices([
        light('l1', false),
        curtain('c1'),
        curtain('c2', status: 'closed', pos: 0),
      ], notifyListeners: false);
      expect(await ctl.evaluateNow(prev, hub.devicesById), 1);
      expect(sent, [('c1', 'curtain', 'close')]); // c2 was already closed
      expect(ctl.log.single.status, 'ok');
      expect(ctl.log.single.steps.map((s) => s.skip), [null, 'already-closed']);
      // same state again: no new transition, no second run
      expect(await ctl.evaluateNow(hub.devicesById, hub.devicesById), 0);
      expect(sent.length, 1);
    });

    test('direct mode: time rule fires once per day and survives a restart of the controller', () async {
      await setUpCtl();
      clock = DateTime(2026, 9, 29, 6, 0);
      await ctl.save(templateById('wake-open-curtains')!.build('wake', time: '07:00'));
      hub.debugSetDevices([curtain('c1', status: 'closed', pos: 0)]);
      hub.debugCommandHook = (id, cap, action, p) async => sent.add((id, cap, action));
      clock = DateTime(2026, 9, 29, 7, 1);
      expect(await ctl.evaluateNow(null, hub.devicesById), 1);
      expect(await ctl.evaluateNow(null, hub.devicesById), 0);
      expect(sent, [('c1', 'curtain', 'open')]);
      // "restart": a new controller reading the same store must not fire again today
      final ctl2 = AutomationController(
        hub: hub,
        store: RuleStore(await SharedPreferences.getInstance()),
        now: () => clock,
        tick: const Duration(days: 1),
      );
      await ctl2.load();
      expect(ctl2.rules.length, 1);
      expect(await ctl2.evaluateNow(null, hub.devicesById), 0);
      ctl2.dispose();
    });

    test(
      'a rule created after its time today does not fire retroactively; the app in background does nothing',
      () async {
        await setUpCtl();
        clock = DateTime(2026, 9, 29, 7, 3);
        await ctl.save(templateById('wake-open-curtains')!.build('late', time: '07:00'));
        hub.debugSetDevices([curtain('c1', status: 'closed', pos: 0)]);
        hub.debugCommandHook = (id, cap, action, p) async => sent.add((id, cap, action));
        expect(await ctl.evaluateNow(null, hub.devicesById), 0);
        clock = DateTime(2026, 9, 30, 7, 0);
        ctl.setForeground(false);
        expect(await ctl.evaluateNow(null, hub.devicesById), 0); // best effort: not while backgrounded
        ctl.setForeground(true);
        await Future<void>.delayed(Duration.zero); // catch-up pass on resume
        expect(sent, [('c1', 'curtain', 'open')]);
      },
    );

    test('one failing device does not stop the others; log records partial failure', () async {
      await setUpCtl();
      await ctl.save(
        const Rule(
          id: 'sleep',
          name: '잠',
          trigger: Trigger.event('sleep'),
          actions: [
            RuleAction(
              selector: Selector(capability: 'curtain'),
              capability: 'curtain',
              action: 'close',
            ),
          ],
        ),
      );
      hub.debugSetDevices([curtain('c1'), curtain('c2')]);
      hub.debugCommandHook = (id, cap, action, p) async {
        if (id == 'c1') throw const HubApiException(502, 'vendor down');
        sent.add((id, cap, action));
      };
      expect(await ctl.fireEvent('sleep'), 1);
      expect(sent, [('c2', 'curtain', 'close')]);
      expect(ctl.log.first.status, 'partial');
      expect(ctl.log.first.steps.firstWhere((s) => !s.ok).error, 'vendor down');
    });

    test('run log and rules persist; corrupt stored data is ignored', () async {
      await setUpCtl();
      await ctl.save(bedtime);
      await ctl.setEnabled('bed', false);
      final prefs = await SharedPreferences.getInstance();
      final s = RuleStore(prefs);
      expect(s.loadRules().single.enabled, isFalse);
      await prefs.setStringList('automation.rules', ['{oops', jsonEncode(bedtime.toJson())]);
      expect(RuleStore(prefs).loadRules().length, 1);
    });
  });

  group('SmartThings Rules API export', () {
    Device stDev(
      String cloudId,
      String kind,
      String cap,
      List<String> actions,
      Map<String, dynamic> state, {
      Map<String, dynamic>? meta,
    }) => Device(
      id: 'smartthings:$cloudId',
      name: cloudId,
      adapter: 'smartthings',
      kind: kind,
      controllable: true,
      reachable: true,
      capabilities: {cap: CapabilityInstance(key: cap, actions: actions, state: state)},
      meta: {
        'cloudId': cloudId,
        'components': {cap: 'main'},
        'stCapabilities': {
          'main': cap == 'curtain' ? ['windowShade', 'windowShadeLevel'] : ['switch'],
        },
        ...?meta,
      },
    );
    final devices = [
      stDev('L1', 'light', 'power', ['turnOn', 'turnOff'], {'switch': 'on'}),
      stDev('L2', 'light', 'power', ['turnOn', 'turnOff'], {'switch': 'off'}),
      stDev('C1', 'curtain', 'curtain', ['open', 'close', 'stop', 'setPosition'], {'position': 100, 'status': 'open'}),
      stDev('C2', 'curtain', 'curtain', ['open', 'close', 'stop', 'setPosition'], {'position': 100, 'status': 'open'}),
    ];

    test(
      'bedtime rule -> allLightsOff via aggregation All + time window, close command grouped over both curtains',
      () {
        final j = buildStRule(bedtime, devices, timeZoneId: 'Asia/Seoul').json;
        expect(j['name'], '취침 시 커튼 닫기');
        final ifAction = (j['actions'] as List).single['if'] as Map;
        final and = ifAction['and'] as List;
        final changes = (and[0] as Map)['changes']['equals'] as Map;
        expect(changes['aggregation'], 'All');
        expect(changes['right'], {'string': 'off'});
        expect(changes['left']['device']['devices'], ['L1', 'L2']);
        expect(changes['left']['device']['trigger'], 'Always');
        // 22:00-02:00 crosses midnight -> or(22:00..24:00, 00:00..02:00)
        final window = (and[1] as Map)['or'] as List;
        expect((window[0] as Map)['between']['start']['time']['offset']['value'], {'integer': 1320});
        expect((window[1] as Map)['between']['end']['time']['offset']['value'], {'integer': 120});
        final cmd = (ifAction['then'] as List).single['command'] as Map;
        expect(cmd['devices'], ['C1', 'C2']);
        expect(cmd['commands'].single, {
          'component': 'main',
          'capability': 'windowShade',
          'command': 'close',
          'arguments': [],
        });
      },
    );

    test('wake rule -> every/specific at Midnight + 07:00 offset with daysOfWeek', () {
      final r = templateById('wake-open-curtains')!
          .build('w', time: '07:30')
          .copyWith(trigger: const Trigger.time('07:30', days: [1, 2, 3, 4, 5]));
      final e = (buildStRule(r, devices, timeZoneId: 'Asia/Seoul').json['actions'] as List).single['every'] as Map;
      expect(e['specific']['reference'], 'Midnight');
      expect(e['specific']['offset'], {
        'value': {'integer': 450},
        'unit': 'Minute',
      });
      expect(e['specific']['daysOfWeek'], ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']);
      expect(e['actions'].single['command']['commands'].single['command'], 'open');
    });

    test('things Samsung cannot run are refused with a Korean reason', () {
      expect(
        () => buildStRule(templateById('leaving-lights-off')!.build('x'), devices),
        throwsA(isA<StRuleUnsupported>()),
      );
      expect(() => buildStRule(bedtime, [devices[2]]), throwsA(isA<StRuleUnsupported>())); // no ST light
      expect(() => buildStRule(bedtime, [devices[0]]), throwsA(isA<StRuleUnsupported>())); // nothing to command
      const toggle = Rule(
        id: 't',
        name: 't',
        trigger: Trigger.time('07:00'),
        actions: [
          RuleAction(
            selector: Selector(kind: 'light'),
            capability: 'power',
            action: 'toggle',
          ),
        ],
      );
      expect(() => buildStRule(toggle, devices), throwsA(isA<StRuleUnsupported>()));
      // non-SmartThings devices are never targeted
      final foreign = curtain('lg-curtain');
      expect(
        () => buildStRule(templateById('wake-open-curtains')!.build('x'), [foreign]),
        throwsA(isA<StRuleUnsupported>()),
      );
    });
  });
}
