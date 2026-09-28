import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeiot/models/capability_spec.dart';
import 'package:homeiot/models/device.dart';
import 'package:homeiot/models/hub_config.dart';
import 'package:homeiot/models/vacuum_map.dart';

import 'fake_hub_api.dart';

void main() {
  group('Device', () {
    final devices = (fixture('devices')['devices'] as List)
        .map((e) => Device.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    Device byId(String id) => devices.firstWhere((d) => d.id == id);

    test('parses hub output with capabilities, actions and state', () {
      final tv = byId('demo:tv');
      expect(tv.kind, 'tv');
      expect(tv.controllable, isTrue);
      expect(tv.powerOn, isTrue);
      expect(tv.cap('volume')!.supports('setLevel'), isTrue);
      expect(tv.cap('mediaInput')!.strings('sources'), contains('HDMI1'));
      expect(tv.room, '거실');
      expect(tv.isExample, isTrue);
    });

    test('nested structures (rooms, consumables, doors)', () {
      final vac = byId('demo:vacuum');
      expect(vac.cap('roomCleaning')!.objects('rooms').first, {'id': '16', 'name': '거실'});
      expect(vac.cap('consumables')!.objects('items').length, 4);
      final fridge = byId('demo:fridge');
      expect(fridge.cap('refrigeration')!.number('freezerSetpoint'), -19);
      expect(byId('demo:washer').cap('washer')!.state['remoteControlEnabled'], isFalse);
    });

    test('tolerates missing optional fields', () {
      final d = Device.fromJson({'id': 'host:1', 'name': null});
      expect(d.name, 'host:1');
      expect(d.kind, 'unknown');
      expect(d.capabilities, isEmpty);
      expect(d.powerOn, isNull);
      expect(d.room, isNull);
    });
  });

  test('CapabilitySpec catalog has a uiHint for every canonical capability', () {
    final specs = CapabilitySpec.parseCatalog(fixture('capabilities'));
    expect(specs['volume']!.uiHint, 'slider+mute');
    expect(specs['mediaInput']!.actions['select']!.keys, ['source']);
    expect(specs['vacuumMap']!.uiHint, 'map-view');
    expect(specs.values.every((s) => s.uiHint.isNotEmpty), isTrue);
  });

  group('HubConfig.parse', () {
    test('host, host:port, url', () {
      expect(HubConfig.parse('192.168.0.5')!.port, 8099);
      final c = HubConfig.parse('192.168.0.5:9000', token: ' s3cret ')!;
      expect((c.host, c.port, c.token), ('192.168.0.5', 9000, 's3cret'));
      expect(HubConfig.parse('http://hub.local:8099')!.host, 'hub.local');
      expect(HubConfig.parse('  '), isNull);
      expect(HubConfig.parse('x', token: '')!.token, isNull);
    });
    test('round-trips JSON and builds ws uri', () {
      final c = HubConfig.fromJson(const HubConfig(host: 'h', port: 1, token: 't').toJson());
      expect(c.wsUri.toString(), 'ws://h:1/ws');
      expect(c.token, 't');
    });
  });

  group('VacuumMap', () {
    final m = VacuumMap.fromJson(fixture('vacuum_map'));

    test('parses image, rooms, robot, dock and PNG', () {
      expect((m.width, m.height), (600.0, 600.0));
      expect(m.rooms.map((r) => r.name), ['거실', '주방', '침실', '욕실']);
      expect(m.robot, const Offset(175, 200));
      expect(m.dock, const Offset(60, 60));
      expect(m.png!.sublist(1, 4), 'PNG'.codeUnits);
      expect(m.isExample, isTrue);
    });

    test('image <-> map transform (y axis flipped)', () {
      final p = m.toMap(const Offset(300, 300));
      expect(p.dx, closeTo(26000, 1e-6));
      expect(p.dy, closeTo(24000, 1e-6));
      final back = m.mapToImage.apply(p);
      expect(back.dx, closeTo(300, 1e-6));
      expect(back.dy, closeTo(300, 1e-6));
    });

    test('room hit test', () {
      expect(m.roomAt(const Offset(100, 100))!.id, '16');
      expect(m.roomAt(const Offset(500, 500))!.name, '침실');
      expect(m.roomAt(const Offset(5, 5)), isNull);
    });

    test('zone rectangle -> normalized map coordinates', () {
      expect(m.zoneToMap(const Rect.fromLTRB(100, 100, 200, 150)), [22000, 27000, 24000, 28000]);
    });

    test('rejects metadata without a transform', () {
      expect(
        () => VacuumMap.fromJson({
          'image': {'width': 1, 'height': 1},
        }),
        throwsFormatException,
      );
    });
  });
}
