import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:homeiot/api/hub_api.dart';
import 'package:homeiot/backend/device_backend.dart';
import 'package:homeiot/models/capability_spec.dart';
import 'package:homeiot/models/device.dart';
import 'package:homeiot/models/hub_config.dart';
import 'package:homeiot/models/vacuum_map.dart';

/// Fixtures are real responses captured from the hub in demo mode
/// (HOMEHUB_FAKE_DEVICES=1), so parsing is tested against actual hub output.
Map<String, dynamic> fixture(String name) =>
    Map<String, dynamic>.from(jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as Map);

class SentCommand {
  SentCommand(this.deviceId, this.capability, this.action, this.params);
  final String deviceId, capability, action;
  final Map<String, dynamic> params;
  @override
  String toString() => '$deviceId $capability.$action $params';
}

class FakeHubApi implements HubApi {
  FakeHubApi({HubConfig? config}) : config = config ?? const HubConfig(host: '192.168.0.10');

  @override
  final HubConfig config;
  @override
  BackendKind get kind => BackendKind.hub;
  @override
  String get title => 'TestHub';
  @override
  String? get subtitle => config.label;
  @override
  bool get hasEventStream => true;
  @override
  Duration? get pollInterval => null;
  @override
  Map<String, String> get warnings => const {};
  final List<SentCommand> commands = [];
  final events$ = StreamController<HubEvent>.broadcast();
  late List<Map<String, dynamic>> deviceJson = (fixture('devices')['devices'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  /// Per "capability.action" error to throw, e.g. {'washer.start': HubApiException(403, ...)}.
  final Map<String, HubApiException> failures = {};
  final List<String> calls = [];
  bool healthy = true;
  Map<String, dynamic> roborock = {'linked': false, 'account': null, 'linkedAt': null, 'devices': []};

  @override
  Future<Map<String, dynamic>> health() async {
    calls.add('health');
    if (!healthy) throw const HubApiException(0, 'unreachable');
    return {'ok': true, 'name': 'TestHub'};
  }

  @override
  Future<Map<String, CapabilitySpec>> capabilities() async => CapabilitySpec.parseCatalog(fixture('capabilities'));

  @override
  Future<List<Device>> devices() async => deviceJson.map(Device.fromJson).toList();

  @override
  Future<Device> device(String id) async => Device.fromJson(deviceJson.firstWhere((d) => d['id'] == id));

  @override
  Future<Device> refresh(String id) => device(id);

  @override
  Future<List<Device>> sync() => devices();

  @override
  Future<List<Device>> scan({bool lan = true, bool cloud = true}) async {
    calls.add('scan');
    return devices();
  }

  @override
  Future<Map<String, dynamic>> command(
    String id,
    String capability,
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    commands.add(SentCommand(id, capability, action, params));
    final f = failures['$capability.$action'];
    if (f != null) throw f;
    return {
      'ok': true,
      'result': {'ok': true},
    };
  }

  @override
  Future<VacuumMap> vacuumMap(String id) async => VacuumMap.fromJson(fixture('vacuum_map'));

  @override
  Future<Map<String, dynamic>> integrations() async => fixture('integrations');

  @override
  Future<Map<String, dynamic>> roborockStatus() async => roborock;

  @override
  Future<Map<String, dynamic>> roborockRequestCode(String email) async {
    calls.add('request-code:$email');
    return {'sent': true};
  }

  @override
  Future<Map<String, dynamic>> roborockLogin(String email, {String? code, String? password}) async {
    calls.add('login:$email:${code ?? ''}');
    roborock = {
      'linked': true,
      'account': 'j***@example.com',
      'devices': [
        {'duid': 'x'},
      ],
    };
    return roborock;
  }

  @override
  Future<Map<String, dynamic>> roborockUnlink() async {
    calls.add('unlink');
    roborock = {'linked': false, 'devices': []};
    return {'linked': false};
  }

  @override
  Stream<HubEvent> events() => events$.stream;

  @override
  void close() {}
}
