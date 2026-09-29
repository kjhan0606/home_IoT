import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/backend/device_backend.dart';
import 'package:homeiot/backend/direct/camera_provider.dart';
import 'package:homeiot/backend/direct/direct_cloud_backend.dart';
import 'package:homeiot/camera/camera_models.dart';
import 'package:homeiot/camera/camera_store.dart';
import 'package:homeiot/state/credentials_store.dart';
import 'package:homeiot/summary/home_summary.dart';

import 'onvif_fixtures.dart';

DirectCameraProvider provider(FakeCamera cam, MemorySecretStore mem, {bool up = true, List<DiscoveredCamera> found = const []}) =>
    DirectCameraProvider(
      CameraStore(mem),
      client: cam.client,
      probe: (h, p) async => up,
      discover: () async => found,
      loadAsset: (a) async => Uint8List.fromList(a.codeUnits),
    );

void main() {
  late FakeCamera cam;
  late MemorySecretStore mem;
  setUp(() {
    cam = FakeCamera();
    mem = MemorySecretStore();
  });

  test('add ONVIF camera: brand-neutral device with PTZ + profiles, password only in secure storage', () async {
    final p = provider(cam, mem);
    final d = await p.add(const NewCamera(protocol: CameraProtocol.onvif, name: '현관', address: '192.168.0.50', username: 'admin', password: 'pw'));
    expect(d.kind, 'camera');
    final vs = d.cap('videoStream')!;
    expect(vs.state['rtspUrl'], 'rtsp://192.168.0.50:554/live/main');
    expect(vs.state['selectedProfile'], 'prof_main'); // H.264 preferred
    expect(vs.supports('selectProfile'), isTrue);
    expect(d.cap('ptz')!.actions, ['move', 'stop', 'gotoPreset']);
    expect(d.toString() + d.meta.toString() + vs.state.toString(), isNot(contains('admin')));
    final feed = await p.feed(d.id);
    expect(feed.rtspUrl, 'rtsp://admin:pw@192.168.0.50:554/live/main'); // credentials joined only in memory
    expect(mem.data[CameraStore.key], contains('"password":"pw"'));
    expect((await p.listDevices()).single.reachable, isTrue);
  });

  test('ONVIF without PTZ or snapshot', () async {
    cam
      ..ptz = false
      ..snapshot = false;
    final d = await provider(cam, mem).add(const NewCamera(protocol: CameraProtocol.onvif, name: 'x', address: '192.168.0.50', username: 'a', password: 'b'));
    expect(d.has('ptz'), isFalse);
    expect(d.cap('videoStream')!.state['snapshotAvailable'], isFalse);
  });

  test('wrong ONVIF password -> 403 and nothing stored', () async {
    final bad = FakeCamera(authOk: false);
    await expectLater(
      provider(bad, mem).add(const NewCamera(protocol: CameraProtocol.onvif, name: 'x', address: '192.168.0.50', username: 'a', password: 'x')),
      throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 403)),
    );
    expect(mem.data, isEmpty);
  });

  test('manual RTSP: embedded credentials move to secure storage; validation; unreachable -> 502', () async {
    final p = provider(cam, mem);
    final d = await p.add(const NewCamera(protocol: CameraProtocol.rtsp, name: '마당', url: 'rtsp://admin:pw@192.168.0.70:554/stream1'));
    expect(d.cap('videoStream')!.state['rtspUrl'], 'rtsp://192.168.0.70:554/stream1');
    expect(d.has('ptz'), isFalse);
    expect((await p.feed(d.id)).rtspUrl, 'rtsp://admin:pw@192.168.0.70:554/stream1');
    await expectLater(p.add(const NewCamera(protocol: CameraProtocol.rtsp, name: 'x', url: 'http://x')), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 400)));
    await expectLater(p.add(const NewCamera(protocol: 'zigbee', name: 'x')), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 400)));
    await expectLater(
      provider(cam, MemorySecretStore(), up: false).add(const NewCamera(protocol: CameraProtocol.rtsp, name: 'x', url: 'rtsp://192.168.0.71/x')),
      throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 502)),
    );
  });

  test('HTTP camera: MJPEG vs JPEG snapshot vs neither; snapshot answers Basic auth', () async {
    final p = provider(cam, mem);
    final a = await p.add(const NewCamera(protocol: CameraProtocol.http, name: 'a', url: 'http://192.168.0.80/video'));
    expect(a.cap('videoStream')!.state['mjpegAvailable'], isTrue);
    cam.snapshotNeedsBasic = true;
    final b = await p.add(const NewCamera(protocol: CameraProtocol.http, name: 'b', url: 'http://192.168.0.81/snap.jpg', username: 'u', password: 'p'));
    final snap = await (await p.feed(b.id)).snapshot();
    expect(snap.toList(), fakeJpeg);
    expect(cam.snapshotAuthHeader, startsWith('Basic '));
    expect((await (await p.feed(a.id)).snapshot()).toList(), fakeJpeg); // first frame of the MJPEG stream
    await expectLater(p.add(const NewCamera(protocol: CameraProtocol.http, name: 'c', url: 'http://192.168.0.82/page')), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 502)));
  });

  test('PTZ + profile commands, validation, and the auto-stop timer', () async {
    final p = provider(cam, mem);
    final d = await p.add(const NewCamera(protocol: CameraProtocol.onvif, name: 'x', address: '192.168.0.50', username: 'a', password: 'b'));
    await p.execute(d, 'ptz', 'move', {'pan': 0.5, 'durationMs': 300});
    expect(cam.soap.last.body, contains('ContinuousMove'));
    for (final bad in [
      {'pan': 2},
      {'pan': 'x'},
      <String, dynamic>{},
      {'pan': 0.1, 'durationMs': 99999},
    ]) {
      await expectLater(p.execute(d, 'ptz', 'move', bad), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 400)), reason: '$bad');
    }
    await p.execute(d, 'ptz', 'gotoPreset', {'preset': '2'});
    await expectLater(p.execute(d, 'ptz', 'gotoPreset', {'preset': '99'}), throwsA(isA<BackendException>()));
    await p.execute(d, 'videoStream', 'selectProfile', {'profile': 'prof_sub'});
    expect((await p.listDevices()).single.cap('videoStream')!.state['selectedProfile'], 'prof_sub');
    await expectLater(p.execute(d, 'videoStream', 'selectProfile', {'profile': 'nope'}), throwsA(isA<BackendException>()));
    await expectLater(p.execute(d, 'ptz', 'explode', {}), throwsA(isA<BackendException>()));
    await Future<void>.delayed(const Duration(milliseconds: 700)); // let the auto-stop fire
    expect(cam.soap.any((c) => c.body.contains('<tptz:Stop>')), isTrue);
    p.close();
  });

  test('PTZ is refused for cameras not added via ONVIF', () async {
    final p = provider(cam, mem);
    final d = await p.add(const NewCamera(protocol: CameraProtocol.rtsp, name: 'x', url: 'rtsp://192.168.0.70/x'));
    await expectLater(p.execute(d, 'ptz', 'stop', {}), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 400)));
  });

  test('demo cameras supply visitorCount/motion so the Home Summary camera line works', () async {
    final p = provider(cam, mem);
    await p.add(const NewCamera(protocol: CameraProtocol.demo, name: '거실 카메라', url: 'living'));
    await p.add(const NewCamera(protocol: CameraProtocol.demo, name: '현관 카메라', url: 'door'));
    final devices = await p.listDevices();
    for (final d in devices) {
      final r = d.cap('sensor')!.state['readings'] as Map;
      expect(r['visitorCount'], isA<int>());
      expect(r['motion'], isA<int>());
    }
    final s = buildHomeSummary(devices, now: DateTime.utc(2026, 9, 29, 12));
    expect(s.attention.map((i) => i.title), contains('현관 카메라 방문자 2명'));
    expect(s.items.where((i) => i.icon == SummaryIcon.camera).length, 2);
    // a real (non-demo) camera has no readings and stays "이상 없음"
    final real = await p.add(const NewCamera(protocol: CameraProtocol.onvif, name: '실제', address: '192.168.0.50', username: 'a', password: 'b'));
    expect(real.cap('sensor'), isNull);
  });

  test('demo cameras: bundled pictures, PTZ changes the picture, no network', () async {
    final p = provider(cam, mem);
    final living = await p.add(const NewCamera(protocol: CameraProtocol.demo, name: '거실', url: 'living'));
    final door = await p.add(const NewCamera(protocol: CameraProtocol.demo, name: '현관', url: 'door'));
    expect(living.isExample, isTrue);
    expect(living.has('ptz'), isTrue);
    expect(door.has('ptz'), isFalse);
    final feed = await p.feed(living.id);
    final a = String.fromCharCodes(await feed.snapshot());
    expect(a, 'assets/demo/demo_living_1_1.jpg');
    await p.execute(living, 'ptz', 'move', {'pan': 1.0, 'durationMs': 300});
    expect(String.fromCharCodes(await feed.snapshot()), 'assets/demo/demo_living_2_1.jpg');
    await p.execute(living, 'ptz', 'gotoPreset', {'preset': '1'});
    expect(String.fromCharCodes(await feed.snapshot()), 'assets/demo/demo_living_0_1.jpg');
    expect(String.fromCharCodes(await (await p.feed(door.id)).snapshot()), 'assets/demo/demo_door.jpg');
    expect(await (await p.feed(door.id)).mjpeg()!.first, isNotEmpty);
    expect(cam.soap, isEmpty);
    expect(cam.gets, isEmpty);
  });

  test('reachability from the probe; remove deletes the stored password', () async {
    final p = provider(cam, mem, up: false);
    final d = await p.add(const NewCamera(protocol: CameraProtocol.demo, name: 'd', url: 'door'));
    expect((await p.listDevices()).single.reachable, isTrue); // demo is always up
    final q = provider(cam, MemorySecretStore());
    await q.add(const NewCamera(protocol: CameraProtocol.rtsp, name: 'r', url: 'rtsp://192.168.0.70/x'));
    final down = DirectCameraProvider(q.store, client: cam.client, probe: (h, pt) async => false);
    expect((await down.listDevices()).single.reachable, isFalse);
    await p.remove(d.id);
    expect(mem.data, isEmpty);
    await expectLater(p.remove(d.id), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 404)));
  });

  test('discovery marks cameras that were already added', () async {
    final p = provider(cam, mem, found: const [DiscoveredCamera(host: '192.168.0.50', name: 'Front'), DiscoveredCamera(host: '192.168.0.51')]);
    await p.add(const NewCamera(protocol: CameraProtocol.onvif, name: 'x', address: '192.168.0.50', username: 'a', password: 'b'));
    final f = await p.discover();
    expect(f.map((c) => c.added), [true, false]);
  });

  test('DirectCloudBackend exposes the camera provider (camera-only mode works without accounts)', () async {
    final be = DirectCloudBackend(providers: [provider(cam, mem)], settleDelay: Duration.zero, pollInterval: null);
    expect(await be.sync(), isEmpty);
    expect(be.canAddDemoCamera, isTrue);
    final d = await be.addCamera(const NewCamera(protocol: CameraProtocol.demo, name: 'd', url: 'living'));
    expect((await be.devices()).map((x) => x.id), [d.id]);
    expect(be.subtitle, contains('IP 카메라'));
    await be.command(d.id, 'ptz', 'move', {'pan': 1.0});
    await be.removeCamera(d.id);
    expect(await be.devices(), isEmpty);
    expect(be.subtitle, isNot(contains('IP 카메라')));
  });
}
