import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/backend/device_backend.dart';
import 'package:homeiot/camera/camera_models.dart';
import 'package:homeiot/camera/camera_store.dart';
import 'package:homeiot/camera/camera_urls.dart';
import 'package:homeiot/camera/http_auth.dart';
import 'package:homeiot/camera/mjpeg.dart';
import 'package:homeiot/camera/onvif_client.dart';
import 'package:homeiot/state/credentials_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'onvif_fixtures.dart';

void main() {
  group('camera URLs', () {
    test('split / join credentials, redact, default ports', () {
      final s = splitCredentials('rtsp://admin:p%40ss@192.168.0.5:554/s1?x=1');
      expect((s.url, s.user, s.password), ('rtsp://192.168.0.5:554/s1?x=1', 'admin', 'p@ss'));
      expect(withCredentials(s.url, s.user, s.password), 'rtsp://admin:p%40ss@192.168.0.5:554/s1?x=1');
      final plain = splitCredentials('rtsp://h/x');
      expect((plain.url, plain.user, plain.password), ('rtsp://h/x', null, null));
      expect(redact('failed rtsp://bob:hunter2@10.0.0.1/x'), isNot(contains('hunter2')));
      expect(defaultPort('rtsp://h/x'), 554);
      expect(defaultPort('http://h:8080/x'), 8080);
      expect(() => splitCredentials('nonsense'), throwsFormatException);
    });
  });

  group('MJPEG splitter', () {
    test('finds frames across arbitrary chunk boundaries', () async {
      final f1 = [0xFF, 0xD8, 0x41, 0x41, 0xFF, 0xD9];
      final f2 = [0xFF, 0xD8, 0x42, 0xFF, 0xD9];
      final stream = <int>[...utf8.encode('--frame\r\nContent-Type: image/jpeg\r\n\r\n'), ...f1, ...utf8.encode('\r\n--frame\r\n\r\n'), ...f2, 13, 10];
      final chunks = <List<int>>[for (var i = 0; i < stream.length; i += 5) stream.sublist(i, i + 5 > stream.length ? stream.length : i + 5)];
      final frames = await jpegFrames(Stream.fromIterable(chunks)).toList();
      expect(frames.map((f) => f.toList()), [f1, f2]);
    });
  });

  group('AuthHttp', () {
    test('answers a Basic challenge', () async {
      String? seen;
      final c = MockClient((r) async {
        seen = r.headers['Authorization'];
        return seen == null ? http.Response('', 401, headers: {'www-authenticate': 'Basic realm="x"'}) : http.Response('ok', 200);
      });
      final r = await AuthHttp(c, username: 'admin', password: 'pw').get(Uri.parse('http://cam/x'));
      expect(r.statusCode, 200);
      expect(seen, 'Basic ${base64.encode(utf8.encode('admin:pw'))}');
    });

    test('answers a Digest challenge with a correct MD5 response', () async {
      String? auth;
      final c = MockClient((r) async {
        auth = r.headers['Authorization'];
        return auth == null
            ? http.Response('', 401, headers: {'www-authenticate': 'Digest realm="cam", nonce="abc123", qop="auth", opaque="op"'})
            : http.Response('ok', 200);
      });
      await AuthHttp(c, username: 'admin', password: 'pw').get(Uri.parse('http://cam/snap.jpg?ch=1'));
      String md5(String s) => crypto.md5.convert(utf8.encode(s)).toString();
      final p = {for (final m in RegExp(r'(\w+)=(?:"([^"]*)"|([^\s,]+))').allMatches(auth!)) m.group(1)!: m.group(2) ?? m.group(3)!};
      final expected = md5('${md5('admin:cam:pw')}:abc123:${p['nc']}:${p['cnonce']}:auth:${md5('GET:/snap.jpg?ch=1')}');
      expect(p['response'], expected);
      expect(p['uri'], '/snap.jpg?ch=1');
      expect(p['opaque'], 'op');
    });
  });

  group('OnvifClient', () {
    OnvifClient client(FakeCamera cam, {String user = 'admin', String pw = 's3cret'}) =>
        OnvifClient(dev, username: user, password: pw, client: cam.client, now: () => DateTime.utc(2026, 9, 29, 0, 0, 0));

    test('full flow: info, services, profiles, stream + snapshot URIs, presets', () async {
      final cam = FakeCamera();
      final c = client(cam);
      expect((await c.deviceInformation())['Model'], 'EC-100');
      await c.discoverServices();
      expect((c.mediaUrl, c.ptzUrl), (media, ptzSvc));
      final profs = await c.profiles();
      expect(profs.map((p) => p['token']), ['prof_main', 'prof_sub']);
      expect((profs[0]['width'], profs[0]['height'], profs[0]['codec'], profs[0]['ptz']), (1920, 1080, 'H264', true));
      expect(await c.streamUri('prof_main'), 'rtsp://192.168.0.50:554/live/main');
      expect(await c.snapshotUri('prof_main'), 'http://192.168.0.50/snap.jpg');
      expect((await c.ptzPresets('prof_main')).map((p) => p['token']), ['1', '2']);
    });

    test('WS-Security digest = Base64(SHA1(nonce + created + password)), clock follows the camera', () async {
      final cam = FakeCamera();
      final c = client(cam);
      await c.deviceInformation();
      final body = cam.soap.last.body;
      expect(body, isNot(contains('s3cret')));
      final nonce = base64.decode(RegExp(r'<Nonce[^>]*>([^<]+)</Nonce>').firstMatch(body)!.group(1)!);
      final created = RegExp(r'<Created[^>]*>([^<]+)</Created>').firstMatch(body)!.group(1)!;
      final digest = RegExp(r'<Password[^>]*>([^<]+)</Password>').firstMatch(body)!.group(1)!;
      expect(digest, base64.encode(crypto.sha1.convert([...nonce, ...utf8.encode(created), ...utf8.encode('s3cret')]).bytes));
      // camera says 01:02:03Z, our clock says 00:00:00Z -> the camera's time is used
      expect(created, '2026-09-29T01:02:03Z');
    });

    test('PTZ requests', () async {
      final cam = FakeCamera();
      final c = client(cam);
      await c.discoverServices();
      await c.ptzMove('prof_main', 0.5, -0.25, 0, timeoutSeconds: 1);
      final b = cam.soap.last.body;
      expect(b, contains('x="0.500" y="-0.250"'));
      expect(b, contains('PT1.0S'));
      expect(b, isNot(contains('<tt:Zoom')));
      await c.ptzStop('prof_main');
      expect(cam.soap.last.body, contains('<tptz:Stop>'));
      await c.ptzGotoPreset('prof_main', '2');
      expect(cam.soap.last.body, contains('<tptz:PresetToken>2</tptz:PresetToken>'));
    });

    test('wrong password is 403; unreachable is 502; no PTZ service is 400', () async {
      final bad = FakeCamera(authOk: false);
      await expectLater(
        client(bad).deviceInformation(),
        throwsA(isA<BackendException>().having((e) => e.statusCode, 'status', 403)),
      );
      final down = OnvifClient(dev, client: MockClient((_) async => throw Exception('boom')));
      await expectLater(down.deviceInformation(), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 502)));
      final c401 = OnvifClient(dev, username: 'a', password: 'b', client: MockClient((_) async => http.Response('', 401)));
      await expectLater(c401.deviceInformation(), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 403)));
      await expectLater(OnvifClient(dev).ptzStop('x'), throwsA(isA<BackendException>().having((e) => e.statusCode, 's', 400)));
    });

    test('normalizeDeviceUrl', () {
      expect(OnvifClient.normalizeDeviceUrl('192.168.0.9'), 'http://192.168.0.9/onvif/device_service');
      expect(OnvifClient.normalizeDeviceUrl('192.168.0.9:8080'), 'http://192.168.0.9:8080/onvif/device_service');
      expect(OnvifClient.normalizeDeviceUrl('http://h/custom'), 'http://h/custom');
      expect(() => OnvifClient.normalizeDeviceUrl('http://'), throwsA(isA<BackendException>()));
    });
  });

  group('WS-Discovery parsing', () {
    const probe = '''<?xml version="1.0"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><e:Body><d:ProbeMatches><d:ProbeMatch>
<d:Types>dn:NetworkVideoTransmitter</d:Types>
<d:Scopes>onvif://www.onvif.org/name/Front%20Door onvif://www.onvif.org/hardware/EC-100 onvif://www.onvif.org/location/country/kr</d:Scopes>
<d:XAddrs>http://192.168.0.50:8080/onvif/device_service http://10.0.0.5/onvif/device_service</d:XAddrs>
</d:ProbeMatch></d:ProbeMatches></e:Body></e:Envelope>''';

    test('parses name, hardware, and picks the XAddr on the source host', () {
      final m = parseProbeMatches(probe, '192.168.0.50').single;
      expect((m.host, m.name, m.hardware), ('192.168.0.50', 'Front Door', 'EC-100'));
      expect(m.onvifUrl, 'http://192.168.0.50:8080/onvif/device_service');
      expect(m.label, 'Front Door');
      expect(parseProbeMatches('not xml'), isEmpty);
      expect(probeMessage('x'), contains('NetworkVideoTransmitter'));
    });
  });

  group('CameraStore + CameraConfig', () {
    test('round trip in secure storage; Device never carries credentials', () async {
      final mem = MemorySecretStore();
      final store = CameraStore(mem);
      const cfg = CameraConfig(
        id: 'camera:1', name: '현관', protocol: CameraProtocol.onvif, username: 'admin', password: 'pw',
        host: '192.168.0.50', onvifUrl: dev, rtspUrl: 'rtsp://192.168.0.50:554/live/main',
        profiles: [
          {'token': 'a', 'name': 'A', 'codec': 'H264', 'width': 1, 'height': 2},
          {'token': 'b', 'name': 'B'},
        ],
        selectedProfile: 'a', ptzPanTilt: true, ptzZoom: true, presets: [{'token': '1', 'name': 'Door'}],
      );
      await store.put(cfg);
      expect(mem.data.keys, [CameraStore.key]);
      final back = (await store.list()).single;
      expect((back.username, back.password, back.hasPtz), ('admin', 'pw', true));
      final d = back.toDevice(reachable: true);
      expect(d.kind, 'camera');
      expect(d.cap('videoStream')!.supports('selectProfile'), isTrue);
      expect(d.cap('ptz')!.actions, ['move', 'stop', 'gotoPreset']);
      expect(jsonEncode({'s': d.cap('videoStream')!.state, 'p': d.cap('ptz')!.state, 'm': d.meta}), isNot(contains('pw')));
      expect(await store.remove('camera:1'), isTrue);
      expect(await store.remove('camera:1'), isFalse);
      expect(mem.data, isEmpty);
    });

    test('corrupt storage yields an empty list', () async {
      final mem = MemorySecretStore()..data[CameraStore.key] = '{not json';
      expect(await CameraStore(mem).list(), isEmpty);
    });
  });

  test('streams close cleanly (sanity for Stream helpers)', () async {
    final c = StreamController<List<int>>();
    final f = jpegFrames(c.stream).toList();
    c.add([0xFF, 0xD8, 1, 0xFF, 0xD9]);
    await c.close();
    expect((await f).single, isA<Uint8List>());
  });
}
