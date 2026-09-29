import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/api/hub_discovery.dart';
import 'package:homeiot/app.dart';
import 'package:homeiot/automation/automation_controller.dart';
import 'package:homeiot/automation/away.dart';
import 'package:homeiot/automation/rule_store.dart';
import 'package:homeiot/models/device.dart';
import 'package:homeiot/models/hub_config.dart';
import 'package:homeiot/screens/automation_screen.dart';
import 'package:homeiot/screens/away_screen.dart';
import 'package:homeiot/state/hub_state.dart';
import 'package:homeiot/state/settings_store.dart';
import 'package:homeiot/summary/home_summary.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_hub_api.dart';
import 'widget_test.dart' show FakeDiscovery;

final _fixture = jsonDecode(File('test/fixtures/away_scenarios.json').readAsStringSync()) as Map;

Device dev(String id, String room, {String kind = 'light', bool on = false}) => Device(
  id: id,
  name: id,
  kind: kind,
  controllable: true,
  reachable: true,
  meta: {'room': room},
  capabilities: kind == 'curtain'
      ? {
          'curtain': const CapabilityInstance(
            key: 'curtain',
            actions: ['open', 'close', 'stop', 'setPosition'],
            state: {'position': 100, 'status': 'open'},
          ),
        }
      : {
          'power': CapabilityInstance(
            key: 'power',
            actions: const ['turnOn', 'turnOff', 'toggle'],
            state: {'switch': on ? 'on' : 'off'},
          ),
        },
);

const rooms = ['거실', '주방', '욕실', '침실', '현관'];
final planJson = {
  'enabled': true,
  'startDate': '2026-10-01',
  'endDate': '2026-10-05',
  'mode': 'random',
  'seed': 42,
  'windowStart': '18:30',
  'windowEnd': '23:00',
  'endOnArriving': true,
  'lights': {'rooms': rooms, 'devices': <String>[]},
  'curtains': {'enabled': false, 'openAt': '08:00', 'closeAt': '18:30', 'rooms': <String>[], 'devices': <String>[]},
};

void main() {
  group('shared scenarios (same file the hub pytest runs)', () {
    for (final s in (_fixture['scenarios'] as List).cast<Map>()) {
      test(s['name'] as String, () {
        final plan = AwayPlan.fromJson(Map<String, dynamic>.from(s['plan'] as Map));
        expect(jsonEncode(plan.toJson()), jsonEncode(s['plan']), reason: 'same JSON as the hub writes');
        final now = DateTime.parse(s['now'] as String);
        final devs = [for (final d in s['devices'] as List) Device.fromJson(Map<String, dynamic>.from(d as Map))];
        final got = [
          for (final w in awayWants(plan, now, devs)) {'deviceId': w.deviceId, 'action': w.action},
        ];
        expect(jsonEncode(got), jsonEncode(s['wants']));
        final st = awayStatus(plan, now);
        final want = s['status'] as Map;
        expect((st.state.name, st.day, st.days), (want['state'], want['day'], want['days']));
      });
    }

    for (final s in (_fixture['schedules'] as List).cast<Map>()) {
      test('seeded evening: seed ${s['seed']} on ${s['date']} equals the Python schedule', () {
        final plan = AwayPlan.fromJson(Map<String, dynamic>.from(s['plan'] as Map));
        final day = DateTime.parse(s['date'] as String);
        const roomOf = {
          'l-living': '거실',
          'l-kitchen': '주방',
          'l-bath': '욕실',
          'l-bed': '침실',
          'l-door': '현관',
          'l-off': '거실',
        };
        for (final e in (s['lights'] as Map).entries) {
          String f(DateTime t) =>
              '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}T'
              '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
          final got = [
            for (final (a, b) in lightIntervals(plan, day, e.key as String, roomOf[e.key])) [f(a), f(b)],
          ];
          expect(got, e.value, reason: '${e.key}');
        }
      });
    }
  });

  test('Park-Miller generator matches the documented sequence', () {
    final r = AwayRng(42);
    var st = 42 % (2147483647 - 1) + 1;
    for (var i = 0; i < 3; i++) {
      st = st * 48271 % 2147483647;
    }
    for (var i = 0; i < 5; i++) {
      st = st * 48271 % 2147483647;
      expect(r.between(0, 99), (st - 1) % 100);
    }
  });

  test('patterns are realistic for many seeds: living long, bathroom brief, kitchen short, all inside the window', () {
    for (var seed = 0; seed < 25; seed++) {
      final p = AwayPlan.fromJson({...planJson, 'seed': seed});
      for (var day = 1; day <= 5; day++) {
        final d = DateTime(2026, 10, day);
        int total(String room) =>
            [for (final (a, b) in lightIntervals(p, d, 'x-$room', room)) b.difference(a).inMinutes]
                .fold(0, (x, y) => x + y);
        for (final room in rooms) {
          final iv = lightIntervals(p, d, 'x-$room', room);
          expect(iv, isNotEmpty);
          for (final (a, b) in iv) {
            expect(a.isBefore(DateTime(2026, 10, day, 18, 30)), isFalse);
            expect(b.isAfter(DateTime(2026, 10, day, 23)), isFalse);
            expect(b.difference(a).inMinutes, greaterThanOrEqualTo(3));
          }
        }
        expect(total('거실'), greaterThanOrEqualTo(60));
        expect(total('욕실'), lessThanOrEqualTo(45));
        expect(total('주방'), lessThanOrEqualTo(95));
        expect(total('거실'), greaterThan(total('욕실')));
      }
    }
  });

  test('validation gives Korean messages', () {
    AwayPlan p({
      String s = '2026-10-01',
      String e = '2026-10-05',
      List<String> r = const ['거실'],
      String ws = '18:30',
      String we = '23:00',
    }) => AwayPlan(startDate: s, endDate: e, lightRooms: r, windowStart: ws, windowEnd: we);
    p().validate();
    expect(() => p(e: '2026-09-30').validate(), throwsA(isA<FormatException>()));
    expect(() => p(e: '2027-03-01').validate(), throwsA(isA<FormatException>()));
    expect(() => p(r: []).validate(), throwsA(isA<FormatException>()));
    expect(() => p(we: '19:00').validate(), throwsA(isA<FormatException>()));
  });

  test('summary: 휴가 모드 켜짐, 3일째 (and nothing when the plan is over or disabled)', () {
    final plan = AwayPlan.fromJson(planJson);
    var s = buildHomeSummary([dev('l1', '거실')], now: DateTime(2026, 10, 3, 12), away: plan);
    expect(s.progress.first.title, '휴가 모드 켜짐, 3일째');
    expect(s.progress.first.icon, SummaryIcon.away);
    expect(s.oneLine(), '휴가 모드 켜짐, 3일째');
    s = buildHomeSummary([dev('l1', '거실')], now: DateTime(2026, 10, 6, 12), away: plan);
    expect(s.items.where((i) => i.icon == SummaryIcon.away), isEmpty);
    s = buildHomeSummary([dev('l1', '거실')], now: DateTime(2026, 10, 3, 12), away: plan.copyWith(enabled: false));
    expect(s.items.where((i) => i.icon == SummaryIcon.away), isEmpty);
    s = buildHomeSummary([dev('l1', '거실')], now: DateTime(2026, 9, 20), away: plan);
    expect(s.ok.first.title, '휴가 모드 예약됨');
  });

  group('AutomationController: away mode in direct mode (app, best effort)', () {
    late HubState hub;
    late AutomationController ctl;
    late DateTime clock;
    late List<(String, String, String)> sent;
    late List<Device> devices;

    Future<void> setUp0() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      clock = DateTime(2026, 10, 2, 12);
      hub = HubState(settings: SettingsStore(prefs), apiFactory: (_) => FakeHubApi(), now: () => clock);
      ctl = AutomationController(hub: hub, store: RuleStore(prefs), now: () => clock, tick: const Duration(days: 1));
      sent = [];
      devices = [for (final r in rooms) dev('l-$r', r), dev('c1', '침실', kind: 'curtain')];
      hub.debugSetDevices(devices);
      hub.debugCommandHook = (id, cap, action, p) async {
        sent.add((id, cap, action));
        // reflect the change so the next tick sees it
        devices = [
          for (final d in devices)
            if (d.id != id)
              d
            else if (cap == 'power')
              dev(d.id, d.meta['room'] as String, on: action == 'turnOn')
            else
              dev(d.id, d.meta['room'] as String, kind: 'curtain'),
        ];
        hub.debugSetDevices(devices, notifyListeners: false);
      };
    }

    tearDown(() => ctl.dispose());

    Set<String> lit() => {
      for (final d in devices)
        if (d.kind == 'light' && d.cap('power')!.state['switch'] == 'on') d.id,
    };

    test('a week: lights follow the seeded schedule, end off, curtains untouched when disabled', () async {
      await setUp0();
      await ctl.saveAway(AwayPlan.fromJson({...planJson, 'mode': 'random'}));
      expect(hub.summary.items.where((i) => i.icon == SummaryIcon.away), isNotEmpty);
      final plan = ctl.away!;
      final seen = <String>{};
      for (
        var t = DateTime(2026, 10, 1, 12);
        t.isBefore(DateTime(2026, 10, 6, 12));
        t = t.add(const Duration(minutes: 5))
      ) {
        clock = t;
        await ctl.evaluateNow(null, hub.devicesById);
        if (awayStatus(plan, t).active) {
          final expected = {
            for (final w in awayWants(plan, t, devices))
              if (w.action == 'turnOn') w.deviceId,
          };
          expect(lit(), expected, reason: '$t');
        }
        seen.addAll(lit());
      }
      expect(seen, {for (final r in rooms) 'l-$r'});
      expect(lit(), isEmpty);
      expect(sent.every((s) => s.$2 == 'power'), isTrue);
      expect(ctl.awayDone, isTrue);
      expect(ctl.log.first.ruleName, '휴가 모드');
    });

    test('arriving ends it and turns off only what the plan turned on', () async {
      await setUp0();
      devices = [for (final r in rooms) dev('l-$r', r, on: r == '침실'), dev('c1', '침실', kind: 'curtain')];
      hub.debugSetDevices(devices, notifyListeners: false);
      await ctl.saveAway(
        AwayPlan.fromJson({
          ...planJson,
          'mode': 'fixed',
          'lights': {
            'rooms': ['거실', '주방'],
            'devices': <String>[],
          },
        }),
      );
      clock = DateTime(2026, 10, 2, 20);
      await ctl.evaluateNow(null, hub.devicesById);
      expect(lit(), {'l-거실', 'l-주방', 'l-침실'});
      await ctl.fireEvent('arriving');
      expect(lit(), {'l-침실'});
      expect(ctl.awayDone, isTrue);
      expect(hub.summary.items.where((i) => i.icon == SummaryIcon.away), isEmpty);
    });

    test('safety: the app never sends anything but light on/off and curtain open/close', () async {
      await setUp0();
      final ac = Device(
        id: 'ac',
        name: '에어컨',
        kind: 'air_conditioner',
        controllable: true,
        reachable: true,
        meta: {'room': '거실'},
        capabilities: const {
          'power': CapabilityInstance(key: 'power', actions: ['turnOn', 'turnOff'], state: {'switch': 'off'}),
        },
      );
      devices = [...devices, ac];
      hub.debugSetDevices(devices, notifyListeners: false);
      await ctl.saveAway(
        AwayPlan.fromJson({
          ...planJson,
          'mode': 'fixed',
          'lights': {
            'rooms': ['거실'],
            'devices': ['ac'],
          },
        }),
      );
      clock = DateTime(2026, 10, 2, 20);
      await ctl.evaluateNow(null, hub.devicesById);
      expect(sent.map((s) => s.$1), isNot(contains('ac')));
      expect(sent, isNotEmpty);
    });

    test('plan and what it turned on survive an app restart; stop removes it', () async {
      await setUp0();
      await ctl.saveAway(AwayPlan.fromJson({...planJson, 'mode': 'fixed'}));
      clock = DateTime(2026, 10, 2, 20);
      await ctl.evaluateNow(null, hub.devicesById);
      final ctl2 = AutomationController(
        hub: hub,
        store: RuleStore(await SharedPreferences.getInstance()),
        now: () => clock,
        tick: const Duration(days: 1),
      );
      await ctl2.load();
      expect(ctl2.away?.seed, 42);
      await ctl2.stopAway();
      expect(lit(), isEmpty);
      expect(ctl2.away, isNull);
      expect(RuleStore(await SharedPreferences.getInstance()).loadAway(), isNull);
      ctl2.dispose();
    });

    test('invalid plan is rejected with a Korean message and nothing is stored', () async {
      await setUp0();
      await expectLater(
        ctl.saveAway(const AwayPlan(startDate: '2026-10-05', endDate: '2026-10-01', lightRooms: ['거실'])),
        throwsA(isA<FormatException>()),
      );
      expect(ctl.away, isNull);
    });
  });

  group('hub mode: the hub runs the plan, the app only edits it', () {
    testWidgets('template opens the screen; saving sends the plan to the hub; the summary card shows the day', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = FakeHubApi();
      final clock = DateTime(2026, 10, 3, 12);
      final hub = HubState(settings: SettingsStore(prefs), apiFactory: (_) => api, now: () => clock);
      await hub.connect(const HubConfig(host: 'h'));
      final ctl = AutomationController(
        hub: hub,
        store: RuleStore(prefs),
        now: () => clock,
        tick: const Duration(days: 1),
      );
      addTearDown(ctl.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: hub),
            ChangeNotifierProvider.value(value: ctl),
            Provider<HubDiscovery>.value(value: FakeDiscovery()),
          ],
          child: MaterialApp(theme: HomeIotApp.theme(Brightness.light), home: const AutomationScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-rule')));
      await tester.pumpAndSettle();
      expect(find.text('휴가/장기 외출 모드'), findsOneWidget);
      await tester.tap(find.byKey(const Key('template-away-mode')));
      await tester.pumpAndSettle();
      expect(find.byType(AwayScreen), findsOneWidget);
      expect(find.byKey(const Key('away-mode-note')), findsOneWidget);
      // rooms with lights are preselected; choose the fixed mode and save
      expect(find.byKey(const Key('away-room-침실')), findsOneWidget);
      await tester.tap(find.text('정해진 시간'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('away-save')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('away-save')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('away-set'));
      expect(api.awayPlan!['mode'], 'fixed');
      expect((api.awayPlan!['lights'] as Map)['rooms'], contains('침실'));
      expect(api.awayPlan!['curtains'], isA<Map>());
      // back on the list: the away card, and the hub's status text
      expect(find.byKey(const Key('away-card')), findsOneWidget);
      await tester.tap(find.byKey(const Key('away-card')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('away-status')), findsOneWidget);
      await tester.scrollUntilVisible(find.text('오늘 저녁 예정'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('오늘 저녁 예정'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('away-stop')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('away-stop')));
      await tester.pumpAndSettle();
      expect(api.awayPlan, isNull);
    });
  });
}
