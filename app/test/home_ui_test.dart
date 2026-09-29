import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/api/hub_discovery.dart';
import 'package:homeiot/app.dart';
import 'package:homeiot/automation/automation_controller.dart';
import 'package:homeiot/automation/rule_store.dart';
import 'package:homeiot/models/hub_config.dart';
import 'package:homeiot/screens/automation_screen.dart';
import 'package:homeiot/screens/device_detail_screen.dart';
import 'package:homeiot/screens/home_summary_screen.dart';
import 'package:homeiot/state/hub_state.dart';
import 'package:homeiot/state/settings_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_hub_api.dart';
import 'widget_test.dart' show FakeDiscovery;

Map<String, dynamic> cap(String key, List<String> actions, Map<String, dynamic> state) => {
  'key': key,
  'actions': actions,
  'state': state,
};

Map<String, dynamic> dev(String id, String name, String kind, Map<String, dynamic> caps, {String room = '침실'}) => {
  'id': id,
  'name': name,
  'adapter': 'demo',
  'kind': kind,
  'reachable': true,
  'controllable': true,
  'capabilities': caps,
  'meta': {'demo': true, 'room': room},
};

Future<(HubState, FakeHubApi, AutomationController)> pump(
  WidgetTester tester, {
  Widget? home,
  bool withHome = true,
  Map<String, dynamic>? away,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final api = FakeHubApi()..awayPlan = away;
  if (withHome) {
    api.deviceJson
      ..add(
        dev('demo:curtain-bedroom', '침실 커튼 (예시)', 'curtain', {
          'curtain': cap('curtain', ['open', 'close', 'stop', 'setPosition'], {'position': 100, 'status': 'open'}),
        }),
      )
      ..add(
        dev('demo:light-living', '거실 조명 (예시)', 'light', {
          'power': cap('power', ['turnOn', 'turnOff', 'toggle'], {'switch': 'on'}),
        }, room: '거실'),
      )
      ..add(
        dev('demo:cam-entrance', '현관 카메라 (예시)', 'camera', {
          'sensor': cap('sensor', [], {
            'readings': {'visitorCount': 2, 'motion': 0},
          }),
        }, room: '현관'),
      );
  }
  final hub = HubState(settings: SettingsStore(prefs), apiFactory: (_) => api);
  await hub.connect(const HubConfig(host: '192.168.0.10'));
  final ctl = AutomationController(hub: hub, store: RuleStore(prefs), tick: const Duration(days: 1));
  addTearDown(ctl.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: hub),
        ChangeNotifierProvider.value(value: ctl),
        Provider<HubDiscovery>.value(value: FakeDiscovery()),
      ],
      child: home == null ? const HomeIotApp() : MaterialApp(theme: HomeIotApp.theme(Brightness.light), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return (hub, api, ctl);
}

void main() {
  testWidgets('home summary card shows "휴가 모드 켜짐, N일째" when an away plan is running', (tester) async {
    final now = DateTime.now();
    String ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final (_, _, ctl) = await pump(
      tester,
      away: {
        'startDate': ymd(now.subtract(const Duration(days: 2))),
        'endDate': ymd(now.add(const Duration(days: 4))),
        'mode': 'random',
        'seed': 1,
        'lights': {
          'rooms': ['침실'],
        },
      },
    );
    await ctl.load();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const Key('home-summary-away')), matching: find.text('휴가 모드 켜짐, 3일째')),
      findsOneWidget,
    );
  });

  testWidgets('home screen shows the summary card on top; tap opens the prioritized screen', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('home-summary-card')), findsOneWidget);
    // demo washer is running, the entrance camera sees 2 visitors
    expect(find.byKey(const Key('home-summary-line')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('home-summary-line'))).data, '현관 카메라 방문자 2명, 로봇청소기 필터 교체 필요');
    await tester.tap(find.byKey(const Key('home-summary-card')));
    await tester.pumpAndSettle();
    expect(find.byType(HomeSummaryScreen), findsOneWidget);
    expect(find.text('확인 필요  2'), findsOneWidget);
    expect(find.textContaining('진행 중'), findsWidgets);
    expect(find.textContaining('방문자 2명'), findsWidgets);
  });

  testWidgets('no camera in the home -> the summary never mentions one', (tester) async {
    await pump(tester, withHome: false);
    final line = tester.widget<Text>(find.byKey(const Key('home-summary-line'))).data!;
    expect(line, isNot(contains('카메라')));
  });

  testWidgets('curtain card: open / close / stop / position slider send canonical commands', (tester) async {
    final (_, api, _) = await pump(tester, home: const DeviceDetailScreen(deviceId: 'demo:curtain-bedroom'));
    expect(find.byKey(const Key('curtain-status')), findsOneWidget);
    await tester.tap(find.byKey(const Key('curtain-close')));
    await tester.pumpAndSettle();
    expect(api.commands.last.toString(), 'demo:curtain-bedroom curtain.close {}');
    await tester.tap(find.byKey(const Key('curtain-open')));
    await tester.pumpAndSettle();
    expect(api.commands.last.action, 'open');
    await tester.tap(find.byKey(const Key('curtain-stop')));
    await tester.pumpAndSettle();
    expect(api.commands.last.action, 'stop');
    await tester.drag(find.byKey(const Key('curtain-position')), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(api.commands.last.action, 'setPosition');
    expect(api.commands.last.params['position'], lessThan(100));
  });

  testWidgets('rules: create "취침 시 커튼 닫기" from a template, toggle it, see it in the list', (tester) async {
    final (_, api, ctl) = await pump(tester, home: const AutomationScreen());
    expect(find.textContaining('아직 규칙이 없습니다'), findsOneWidget);
    expect(find.byKey(const Key('automation-mode-banner')), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-rule')));
    await tester.pumpAndSettle();
    expect(find.text('취침 시 커튼 닫기'), findsOneWidget);
    expect(find.text('기상 시 커튼 열기'), findsOneWidget);
    await tester.tap(find.byKey(const Key('template-bedtime-close-curtains')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('window-start')), findsOneWidget);
    expect(find.text('22:00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-rule')));
    await tester.pumpAndSettle();
    expect(api.rules.length, 1); // hub mode -> saved on the hub
    expect(ctl.rules.single.name, '취침 시 커튼 닫기');
    expect(find.textContaining('모든 조명이 꺼지면'), findsOneWidget);
    final id = ctl.rules.single.id;
    await tester.tap(find.byKey(Key('rule-switch-$id')));
    await tester.pumpAndSettle();
    expect(api.rules.single['enabled'], false);
  });

  testWidgets('run log tab lists what ran and says so when empty', (tester) async {
    final (_, api, ctl) = await pump(tester, home: const AutomationScreen());
    await tester.tap(find.text('실행 기록'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('log-empty')), findsOneWidget);
    api.runLog.addAll([
      {
        'time': '2026-09-29T22:31:00',
        'ruleId': 'r1',
        'ruleName': '취침 시 커튼 닫기',
        'reason': '모든 조명이 꺼짐',
        'status': 'ok',
        'steps': [
          {'deviceId': 'demo:curtain-bedroom', 'name': '침실 커튼', 'action': 'close', 'ok': true},
        ],
      },
    ]);
    await ctl.load();
    await tester.pumpAndSettle();
    expect(find.text('취침 시 커튼 닫기'), findsOneWidget);
    expect(find.byKey(const Key('log-empty')), findsNothing);
  });
}
