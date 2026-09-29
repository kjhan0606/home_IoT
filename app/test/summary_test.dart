import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/models/device.dart';
import 'package:homeiot/state/hub_state.dart';
import 'package:homeiot/state/settings_store.dart';
import 'package:homeiot/summary/home_summary.dart';
import 'package:homeiot/summary/summary_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_hub_api.dart';

final now = DateTime.utc(2026, 9, 29, 12, 0);

Device d(String id, String name, String kind, Map<String, Map<String, dynamic>> caps, {bool reachable = true}) =>
    Device(
      id: id,
      name: name,
      kind: kind,
      controllable: true,
      reachable: reachable,
      capabilities: {for (final e in caps.entries) e.key: CapabilityInstance(key: e.key, state: e.value)},
    );

Device washer(String state, {String? completion}) => d('w', '세탁기', 'washer', {
  'washer': {'machineState': state, 'completionTime': ?completion, 'remainingMinutes': 30},
});
Device fridge({bool open = false, String? since, num t = 3}) => d('f', '냉장고', 'refrigerator', {
  'refrigeration': {'doorOpen': open, 'doorOpenSince': ?since, 'fridgeTemperature': t, 'unit': 'C'},
});
Device vac(String status, int battery) => d('v', '로봇청소기', 'vacuum', {
  'vacuum': {'status': status, 'battery': battery},
});
Device camera({int visitors = 0, num motion = 0}) => d('cam', '현관 카메라', 'camera', {
  'sensor': {
    'readings': {'visitorCount': visitors, 'motion': motion},
  },
});

void main() {
  test('the example sentence from the brief: 세탁 끝남, 냉장고 문 열림 12분, 로봇청소기 충전 필요, 현관 카메라 방문자 2명', () {
    final s = buildHomeSummary([
      washer('stop', completion: '2026-09-29T11:20:00Z'),
      fridge(open: true, since: '2026-09-29T11:48:00Z'),
      vac('idle', 12),
      camera(visitors: 2),
    ], now: now);
    expect(s.oneLine(), '세탁 끝남, 냉장고 문 열림 12분, 로봇청소기 충전 필요, 현관 카메라 방문자 2명');
    expect(s.attention.length, 4);
    expect(s.attention.first.icon, SummaryIcon.laundry); // ordered by rank
  });

  test('no camera capability in the home -> no camera item at all', () {
    final s = buildHomeSummary([
      washer('stop', completion: '2026-09-29T11:20:00Z'),
      fridge(open: true, since: '2026-09-29T11:48:00Z'),
    ], now: now);
    expect(s.items.where((i) => i.icon == SummaryIcon.camera), isEmpty);
    expect(s.oneLine(), '세탁 끝남, 냉장고 문 열림 12분');
  });

  test('a camera with a videoStream capability but quiet readings is "all good"; motion is attention', () {
    final quiet = d('cam', '거실 카메라', 'unknown', {
      'videoStream': {},
      'sensor': {'readings': {}},
    });
    var s = buildHomeSummary([quiet], now: now);
    expect(s.ok.single.title, '거실 카메라 이상 없음');
    s = buildHomeSummary([camera(motion: 1)], now: now);
    expect(s.attention.single.title, '현관 카메라 움직임 감지');
  });

  test('levels: in progress vs all good', () {
    final s = buildHomeSummary([washer('run'), fridge(), vac('charging', 90)], now: now);
    expect(s.attention, isEmpty);
    expect(s.progress.single.title, '세탁 중 30분 남음');
    expect(s.oneLine(), '세탁 중 30분 남음');
    expect(s.ok.map((i) => i.icon), containsAll([SummaryIcon.fridge, SummaryIcon.vacuum]));
    final calm = buildHomeSummary([fridge(), vac('docked', 90)], now: now);
    expect(calm.oneLine(), '집 안 모두 정상입니다');
    expect(buildHomeSummary(const [], now: now).oneLine(), '표시할 기기가 없습니다');
  });

  test('a docked robot with low battery does not need charging; a stranded one does', () {
    expect(buildHomeSummary([vac('charging', 8)], now: now).attention, isEmpty);
    expect(buildHomeSummary([vac('paused', 8)], now: now).attention.single.title, '로봇청소기 충전 필요');
    expect(buildHomeSummary([vac('error', 50)], now: now).attention.single.title, '로봇청소기 오류');
  });

  test('old completion time is not "just finished"; tracker notices a cycle that ends while watching', () {
    final old = buildHomeSummary([washer('stop', completion: '2026-09-28T08:00:00Z')], now: now);
    expect(old.attention, isEmpty);
    final t = SummaryTracker();
    t.update([washer('run')], now.subtract(const Duration(minutes: 10)));
    t.update([washer('stop')], now.subtract(const Duration(minutes: 5)));
    final s = buildHomeSummary([washer('stop')], now: now, tracker: t);
    expect(s.attention.single.title, '세탁 끝남');
    expect(s.attention.single.detail, contains('5분 전'));
    t.update([washer('run')], now); // restarted -> forgotten
    expect(buildHomeSummary([washer('run')], now: now, tracker: t).attention, isEmpty);
  });

  test('fridge door open duration comes from the tracker when the vendor gives no timestamp', () {
    final t = SummaryTracker()..update([fridge(open: true)], now.subtract(const Duration(minutes: 12)));
    expect(buildHomeSummary([fridge(open: true)], now: now, tracker: t).oneLine(), '냉장고 문 열림 12분');
    expect(buildHomeSummary([fridge(open: true)], now: now).oneLine(), '냉장고 문 열림'); // unknown duration
  });

  test('lights, curtains, unlocked door, offline devices and more than 4 items', () {
    final light = d('l', '거실 조명', 'light', {
      'power': {'switch': 'on'},
    });
    final curtain = d('c', '침실 커튼', 'curtain', {
      'curtain': {'status': 'closed', 'position': 0},
    });
    final lock = d('k', '현관 도어락', 'lock', {
      'lock': {'locked': false},
    });
    final dead = d('x', 'Dead', 'light', {}, reachable: false);
    var s = buildHomeSummary([light, curtain, lock, dead], now: now);
    expect(s.attention.map((i) => i.title), ['현관 도어락 열림', '오프라인 기기 1개']);
    expect(s.progress.single.title, '조명 1개 켜짐');
    expect(s.ok.single.title, '커튼 모두 닫힘');
    s = buildHomeSummary([
      washer('stop', completion: '2026-09-29T11:59:00Z'),
      fridge(open: true),
      vac('idle', 5),
      camera(visitors: 1),
      lock,
      dead,
    ], now: now);
    expect(s.oneLine(), endsWith('외 2건'));
  });

  group('SummaryNotifier (local notification hook)', () {
    late FakeHubApi api;
    late HubState hub;
    late FakeSink sink;
    late DateTime clock;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      clock = DateTime.utc(2026, 9, 29, 12);
      api = FakeHubApi();
      hub = HubState(
        settings: SettingsStore(await SharedPreferences.getInstance()),
        apiFactory: (_) => api,
        now: () => clock,
      );
      sink = FakeSink();
    });

    test('first load is silent; a newly appearing item notifies once with the one-line summary', () async {
      final n = SummaryNotifier(hub: hub, sink: sink);
      hub.debugSetDevices([fridge(), vac('docked', 80)]);
      expect(sink.shown, isEmpty);
      hub.debugSetDevices([fridge(open: true, since: '2026-09-29T11:48:00Z'), vac('docked', 80)]);
      expect(sink.shown.single.$1, '냉장고 문 열림 12분');
      hub.debugSetDevices([fridge(open: true, since: '2026-09-29T11:48:00Z'), vac('docked', 80)]);
      expect(sink.shown.length, 1); // same item: no repeat
      hub.debugSetDevices([fridge(), vac('docked', 80)]);
      hub.debugSetDevices([fridge(open: true), vac('docked', 80)]);
      expect(sink.shown.length, 2); // went away and came back
      hub.debugSetDevices([fridge(open: true), vac('idle', 5)]);
      expect(sink.shown.last.$1, '로봇청소기 충전 필요');
      expect(sink.shown.last.$2, contains('냉장고 문 열림'));
      n.enabled = false;
      hub.debugSetDevices([fridge(open: true), vac('idle', 5), camera(visitors: 2)]);
      expect(sink.shown.length, 3);
      n.dispose();
    });
  });
}

class FakeSink implements NotificationSink {
  final List<(String, String)> shown = [];
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> show({required String title, required String body}) async => shown.add((title, body));
}
