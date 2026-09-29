import 'dart:async';

import '../../camera/camera_models.dart';
import '../../models/canonical_catalog.dart';
import '../../models/capability_spec.dart';
import '../../models/device.dart';
import '../../models/vacuum_map.dart';
import '../device_backend.dart';
import 'camera_provider.dart';
import 'cloud_provider.dart';

/// [DeviceBackend] that needs no server: the app talks to each vendor cloud
/// itself through a [CloudProvider] (SmartThings, LG ThinQ, ...) and merges
/// their brand-neutral devices into one list.
///
/// Routing is by `Device.adapter` (= provider id) -- the UI never sees it.
/// One provider failing (e.g. an expired SmartThings PAT) does not hide the
/// others: the failure is reported through [warnings] and only its devices
/// disappear.
class DirectCloudBackend implements DeviceBackend, CameraBackend {
  DirectCloudBackend({
    required List<CloudProvider> providers,
    this.pollInterval = const Duration(seconds: 60),
    this.settleDelay = const Duration(milliseconds: 800),
  }) : _providers = {for (final p in providers) p.id: p};

  final Map<String, CloudProvider> _providers;
  final Map<String, Device> _devices = {};
  final Map<String, String> _warnings = {};

  /// How long to wait after a command before re-reading the device (clouds
  /// apply commands asynchronously). Tests pass [Duration.zero].
  final Duration settleDelay;

  @override
  final Duration? pollInterval;

  @override
  BackendKind get kind => BackendKind.directCloud;
  @override
  String get title => '직접 연결';
  @override
  String? get subtitle {
    final names = [
      for (final p in _providers.values)
        if (p is! DirectCameraProvider) p.name.replaceAll(' (cloud)', ''),
      if (_devices.values.any((d) => d.kind == 'camera')) 'IP 카메라',
    ];
    return names.join(' · ');
  }
  @override
  bool get hasEventStream => false;
  @override
  Map<String, String> get warnings => Map.unmodifiable(_warnings);

  /// The SmartThings provider, if a SmartThings token is configured (used for the Rules API).
  CloudProvider? provider(String id) => _providers[id];

  /// Ids of the configured providers.
  Iterable<String> get providerIds => _providers.keys;

  @override
  Future<Map<String, CapabilitySpec>> capabilities() async => canonicalCatalog;

  @override
  Future<List<Device>> devices() async => _devices.values.toList();

  @override
  Future<Device> device(String id) async {
    final d = _devices[id];
    if (d == null) throw const BackendException(404, '기기를 찾을 수 없습니다.');
    return d;
  }

  /// Lists every provider's devices. Throws only if *every* provider failed
  /// (the first error); otherwise failures become [warnings].
  @override
  Future<List<Device>> sync() async {
    if (_providers.isEmpty) {
      _devices.clear();
      return [];
    }
    final results = await Future.wait(
      _providers.values.map((p) async {
        try {
          return (p, await p.listDevices(), null as BackendException?);
        } on BackendException catch (e) {
          return (p, const <Device>[], e);
        }
      }),
    );
    final failures = results.where((r) => r.$3 != null).toList();
    // The (always present, account-less) camera provider must not mask an
    // "every cloud failed" error when there are no cameras to show.
    final onlyFailedOrEmptyCameras = results.every((r) => r.$3 != null || (r.$1 is DirectCameraProvider && r.$2.isEmpty));
    if (failures.isNotEmpty && onlyFailedOrEmptyCameras) {
      _warnings
        ..clear()
        ..addEntries(failures.map((f) => MapEntry(f.$1.id, f.$3!.message)));
      throw failures.first.$3!;
    }
    _warnings.clear();
    final next = <String, Device>{};
    for (final (provider, devs, err) in results) {
      if (err == null) {
        for (final d in devs) {
          next[d.id] = d;
        }
      } else {
        _warnings[provider.id] = err.message;
        // Transient (non-auth) failure: keep the last known devices.
        if (err is! CloudAuthException) {
          next.addAll({
            for (final e in _devices.entries)
              if (e.value.adapter == provider.id) e.key: e.value,
          });
        }
      }
    }
    _devices
      ..clear()
      ..addAll(next);
    return _devices.values.toList();
  }

  @override
  Future<List<Device>> scan({bool lan = true, bool cloud = true}) => sync();

  CloudProvider _providerFor(Device d) {
    final p = _providers[d.adapter];
    if (p == null) throw const BackendException(404, '이 기기의 연동이 설정되어 있지 않습니다.');
    return p;
  }

  @override
  Future<Device> refresh(String id) async {
    final d = await device(id);
    final fresh = await _providerFor(d).refresh(d);
    _devices[id] = fresh;
    return fresh;
  }

  @override
  Future<Map<String, dynamic>> command(
    String id,
    String capability,
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    final d = await device(id);
    if (!d.controllable) throw const BackendException(400, '제어할 수 없는 기기입니다.');
    if (!d.has(capability)) throw BackendException(400, '이 기기는 $capability 기능이 없습니다.');
    final res = await _providerFor(d).execute(d, capability, action, params);
    // Best effort: pick up the new state (cloud applies commands asynchronously).
    // (cameras answer immediately; waiting would make PTZ feel sluggish)
    if (settleDelay > Duration.zero && d.kind != 'camera') await Future<void>.delayed(settleDelay);
    try {
      await refresh(id);
    } catch (_) {}
    return res;
  }

  @override
  Future<VacuumMap> vacuumMap(String id) async => throw const BackendException(501, '직접 연결 모드에서는 청소기 지도를 지원하지 않습니다.');

  @override
  Stream<BackendEvent> events() => const Stream.empty();

  // ------------------------------------------------------------- cameras ----
  DirectCameraProvider get _cameras {
    final p = _providers['camera'];
    if (p is DirectCameraProvider) return p;
    throw const BackendException(501, '이 연결 방식에서는 카메라를 지원하지 않습니다.');
  }

  @override
  bool get canAddDemoCamera => _providers['camera'] is DirectCameraProvider;

  @override
  Future<CameraFeed> cameraFeed(String deviceId) => _cameras.feed(deviceId);

  @override
  Future<List<DiscoveredCamera>> discoverCameras() => _cameras.discover();

  @override
  Future<Device> addCamera(NewCamera camera) async {
    final d = await _cameras.add(camera);
    _devices[d.id] = d;
    return d;
  }

  @override
  Future<void> removeCamera(String deviceId) async {
    await _cameras.remove(deviceId);
    _devices.remove(deviceId);
  }

  @override
  void close() {
    for (final p in _providers.values) {
      p.close();
    }
  }
}
