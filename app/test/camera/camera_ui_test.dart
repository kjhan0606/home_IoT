import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/api/hub_discovery.dart';
import 'package:homeiot/app.dart';
import 'package:homeiot/backend/device_backend.dart';
import 'package:homeiot/camera/camera_models.dart';
import 'package:homeiot/camera/camera_player.dart';
import 'package:homeiot/models/device.dart';
import 'package:homeiot/models/hub_config.dart';
import 'package:homeiot/screens/add_camera_screen.dart';
import 'package:homeiot/state/hub_state.dart';
import 'package:homeiot/state/settings_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_hub_api.dart';
import 'onvif_fixtures.dart' as fx;

class _NoDiscovery implements HubDiscovery {
  @override
  bool get supported => false;
  @override
  Stream<List<HubConfig>> discover() => const Stream.empty();
  @override
  Future<void> stop() async {}
}

// a real 1x1 PNG so Image.memory can decode it
final _jpeg = Uint8List.fromList(const [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0, 5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130
]);

class FakeFeed implements CameraFeed {
  FakeFeed({this.rtsp, this.fail = false});
  final String? rtsp;
  final bool fail;
  int snapshots = 0;
  @override
  Future<Uint8List> snapshot() async {
    snapshots++;
    if (fail) throw const BackendException(502, '카메라에 연결할 수 없습니다.');
    return _jpeg;
  }

  @override
  Stream<Uint8List>? mjpeg() => null;
  @override
  String? get rtspUrl => rtsp;
  @override
  bool get hasSnapshot => true;
}

/// Hub fixture + cameras, exposing the optional CameraBackend interface.
class CameraFakeHub extends FakeHubApi implements CameraBackend {
  final List<NewCamera> added = [];
  final List<String> removed = [];
  FakeFeed feed = FakeFeed();
  Object? addError;
  List<DiscoveredCamera> discovered = const [DiscoveredCamera(host: '192.168.0.50', name: 'Front Door', onvifUrl: fx.dev)];

  CameraFakeHub() {
    deviceJson = [
      ...deviceJson,
      ...(fixture('camera_devices')['devices'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
    ];
  }

  @override
  bool get canAddDemoCamera => false;
  @override
  Future<CameraFeed> cameraFeed(String id) async => feed;
  @override
  Future<List<DiscoveredCamera>> discoverCameras() async => discovered;
  @override
  Future<Device> addCamera(NewCamera c) async {
    if (addError != null) throw addError!;
    added.add(c);
    return Device.fromJson(deviceJson.firstWhere((d) => d['kind'] == 'camera'));
  }

  @override
  Future<void> removeCamera(String id) async => removed.add(id);
}

Future<(HubState, CameraFakeHub)> pumpCam(WidgetTester tester, {Widget? home}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final api = CameraFakeHub();
  final hub = HubState(settings: SettingsStore(await SharedPreferences.getInstance()), apiFactory: (_) => api);
  await hub.connect(const HubConfig(host: '192.168.0.10'));
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: hub),
        Provider<HubDiscovery>.value(value: _NoDiscovery()),
      ],
      child: home == null ? const HomeIotApp() : MaterialApp(theme: HomeIotApp.theme(Brightness.light), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return (hub, api);
}

void main() {
  tearDown(() => CameraPlayer.rtspBuilder = null);

  testWidgets('device list shows a camera grid (not list tiles) and an add-camera button', (tester) async {
    await pumpCam(tester);
    expect(find.byKey(const Key('camera-grid')), findsOneWidget);
    expect(find.byKey(const Key('device-demo:cam-living')), findsOneWidget);
    expect(find.text('거실 카메라 (예시)'), findsOneWidget);
    expect(find.byKey(const Key('add-camera')), findsOneWidget);
  });

  testWidgets('no camera UI when no cameras and the backend has no camera support', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final api = FakeHubApi(); // plain hub fake: not a CameraBackend
    final hub = HubState(settings: SettingsStore(await SharedPreferences.getInstance()), apiFactory: (_) => api);
    await hub.connect(const HubConfig(host: '192.168.0.10'));
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: hub), Provider<HubDiscovery>.value(value: _NoDiscovery())],
        child: const HomeIotApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-grid')), findsNothing);
    expect(find.byKey(const Key('add-camera')), findsNothing);
  });

  testWidgets('camera screen: snapshot view, PTZ pad sends move/stop, presets, from canonical capabilities only', (tester) async {
    final (_, api) = await pumpCam(tester);
    await tester.tap(find.byKey(const Key('device-demo:cam-living')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-frame')), findsOneWidget);
    expect(api.feed.snapshots, greaterThan(0));
    expect(find.byKey(const Key('ptz-up')), findsOneWidget);
    expect(find.byKey(const Key('preset-1')), findsOneWidget);

    final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('ptz-right'))));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    final cmds = api.commands.where((c) => c.deviceId == 'demo:cam-living').toList();
    expect(cmds.first.capability, 'ptz');
    expect(cmds.first.action, 'move');
    expect(cmds.first.params['pan'], greaterThan(0));
    expect(cmds.last.action, 'stop');

    await tester.tap(find.byKey(const Key('preset-2')));
    await tester.pumpAndSettle();
    expect(api.commands.last.action, 'gotoPreset');
    expect(api.commands.last.params, {'preset': '2'});

    await tester.tap(find.byKey(const Key('refresh-snapshot')));
    await tester.pumpAndSettle();
    expect(api.feed.snapshots, greaterThan(1));
    // privacy / safety note is on the page
    expect(find.textContaining('PIPA', skipOffstage: false), findsOneWidget);
  });

  testWidgets('a camera without ptz shows no PTZ pad', (tester) async {
    await pumpCam(tester);
    await tester.tap(find.byKey(const Key('device-demo:cam-door')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-frame')), findsOneWidget);
    expect(find.byKey(const Key('ptz-up')), findsNothing);
  });

  testWidgets('snapshot failure shows the reason instead of a picture', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final api = CameraFakeHub()..feed = FakeFeed(fail: true);
    final hub = HubState(settings: SettingsStore(await SharedPreferences.getInstance()), apiFactory: (_) => api);
    await hub.connect(const HubConfig(host: '192.168.0.10'));
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: hub), Provider<HubDiscovery>.value(value: _NoDiscovery())],
        child: const HomeIotApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-demo:cam-door')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-frame')), findsNothing);
    expect(find.text('카메라에 연결할 수 없습니다.'), findsOneWidget);
  });

  testWidgets('RTSP player is preferred when available; its failure falls back to snapshots', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    VoidCallback? fail;
    CameraPlayer.rtspBuilder = (ctx, url, onError) {
      fail = onError;
      return Text('player:$url', key: const Key('rtsp-player'));
    };
    final api = CameraFakeHub()..feed = FakeFeed(rtsp: 'rtsp://admin:pw@192.168.0.50/x');
    final hub = HubState(settings: SettingsStore(await SharedPreferences.getInstance()), apiFactory: (_) => api);
    await hub.connect(const HubConfig(host: '192.168.0.10'));
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: hub), Provider<HubDiscovery>.value(value: _NoDiscovery())],
        child: const HomeIotApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-demo:cam-living')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rtsp-player')), findsOneWidget);
    expect(find.byKey(const Key('mode-rtsp')), findsOneWidget);
    expect(find.byKey(const Key('mode-snapshot')), findsOneWidget);
    fail!();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rtsp-player')), findsNothing);
    expect(find.byKey(const Key('camera-frame')), findsOneWidget);
  });

  testWidgets('add camera: discovered ONVIF camera + password is sent, then list reloads', (tester) async {
    final (_, api) = await pumpCam(tester, home: const AddCameraScreen());
    expect(find.byKey(const Key('found-192.168.0.50')), findsOneWidget);
    await tester.tap(find.byKey(const Key('found-192.168.0.50')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('camera-user')), 'admin');
    await tester.enterText(find.byKey(const Key('camera-pass')), 's3cret');
    await tester.ensureVisible(find.byKey(const Key('camera-add')));
    await tester.tap(find.byKey(const Key('camera-add')));
    await tester.pumpAndSettle();
    final c = api.added.single;
    expect((c.protocol, c.address, c.username, c.password, c.name), ('onvif', fx.dev, 'admin', 's3cret', 'Front Door'));
    expect(find.text('카메라 추가'), findsNothing); // popped
  });

  testWidgets('add camera: manual RTSP URL, password field is obscured, wrong password shows a clear message', (tester) async {
    final (_, api) = await pumpCam(tester, home: const AddCameraScreen());
    api.addError = const BackendException(403, 'camera rejected');
    await tester.tap(find.text('주소 입력'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('camera-pass'))).obscureText, isTrue);
    await tester.enterText(find.byKey(const Key('camera-url')), 'rtsp://192.168.0.70:554/stream1');
    await tester.enterText(find.byKey(const Key('camera-name')), '마당');
    await tester.enterText(find.byKey(const Key('camera-pass')), 'bad');
    await tester.ensureVisible(find.byKey(const Key('camera-add')));
    await tester.tap(find.byKey(const Key('camera-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-error')), findsOneWidget);
    expect(find.textContaining('거부'), findsOneWidget);
    expect(find.textContaining('PIPA', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('인터넷으로 열지', skipOffstage: false), findsOneWidget);
    // empty URL is rejected locally
    await tester.enterText(find.byKey(const Key('camera-url')), '');
    await tester.tap(find.byKey(const Key('camera-add')));
    await tester.pumpAndSettle();
    expect(find.text('카메라 주소를 입력하세요.'), findsOneWidget);
  });

  testWidgets('remove camera asks for confirmation and calls the backend', (tester) async {
    final (_, api) = await pumpCam(tester);
    // the fixture cameras are demo (example) data -> no remove menu; make one real
    api.deviceJson = [
      for (final d in api.deviceJson)
        if (d['id'] == 'demo:cam-door') {...d, 'meta': <String, dynamic>{}} else d,
    ];
    await (tester.element(find.byType(Scaffold).first)).read<HubState>().reload();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-demo:cam-door')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('camera-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('카메라 삭제').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('비밀번호도 함께 삭제'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-remove-camera')));
    await tester.pumpAndSettle();
    expect(api.removed, ['demo:cam-door']);
  });

}
