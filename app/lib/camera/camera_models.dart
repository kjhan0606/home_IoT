import 'dart:typed_data';

import '../models/device.dart';

/// How a camera was added. Purely informational for the UI (never used to pick
/// widgets) -- the UI is driven by the `videoStream` / `ptz` capabilities.
class CameraProtocol {
  static const onvif = 'onvif';
  static const rtsp = 'rtsp';
  static const http = 'http';
  static const demo = 'demo';
}

/// A camera as stored on this phone (direct mode). The password lives in
/// secure storage next to the rest of this JSON; it is never put in a [Device].
class CameraConfig {
  const CameraConfig({
    required this.id,
    required this.name,
    required this.protocol,
    this.username = '',
    this.password = '',
    this.host,
    this.onvifUrl,
    this.rtspUrl,
    this.snapshotUrl,
    this.mjpegUrl,
    this.vendor,
    this.model,
    this.room,
    this.profiles = const [],
    this.selectedProfile,
    this.ptzPanTilt = false,
    this.ptzZoom = false,
    this.presets = const [],
    this.demoScene,
  });

  final String id, name, protocol;
  final String username, password;
  final String? host, onvifUrl, rtspUrl, snapshotUrl, mjpegUrl, vendor, model, room, selectedProfile, demoScene;
  final List<Map<String, dynamic>> profiles;
  final bool ptzPanTilt, ptzZoom;
  final List<Map<String, dynamic>> presets;

  bool get hasPtz => ptzPanTilt || ptzZoom;
  bool get snapshotAvailable => snapshotUrl != null || mjpegUrl != null || demoScene != null;

  CameraConfig copyWith({String? selectedProfile, String? rtspUrl, String? snapshotUrl}) => CameraConfig(
    id: id,
    name: name,
    protocol: protocol,
    username: username,
    password: password,
    host: host,
    onvifUrl: onvifUrl,
    rtspUrl: rtspUrl ?? this.rtspUrl,
    snapshotUrl: snapshotUrl ?? this.snapshotUrl,
    mjpegUrl: mjpegUrl,
    vendor: vendor,
    model: model,
    room: room,
    profiles: profiles,
    selectedProfile: selectedProfile ?? this.selectedProfile,
    ptzPanTilt: ptzPanTilt,
    ptzZoom: ptzZoom,
    presets: presets,
    demoScene: demoScene,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol,
    'username': username,
    'password': password,
    'host': host,
    'onvifUrl': onvifUrl,
    'rtspUrl': rtspUrl,
    'snapshotUrl': snapshotUrl,
    'mjpegUrl': mjpegUrl,
    'vendor': vendor,
    'model': model,
    'room': room,
    'profiles': profiles,
    'selectedProfile': selectedProfile,
    'ptzPanTilt': ptzPanTilt,
    'ptzZoom': ptzZoom,
    'presets': presets,
    'demoScene': demoScene,
  };

  factory CameraConfig.fromJson(Map<String, dynamic> j) => CameraConfig(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '카메라',
    protocol: (j['protocol'] as String?) ?? CameraProtocol.rtsp,
    username: (j['username'] as String?) ?? '',
    password: (j['password'] as String?) ?? '',
    host: j['host'] as String?,
    onvifUrl: j['onvifUrl'] as String?,
    rtspUrl: j['rtspUrl'] as String?,
    snapshotUrl: j['snapshotUrl'] as String?,
    mjpegUrl: j['mjpegUrl'] as String?,
    vendor: j['vendor'] as String?,
    model: j['model'] as String?,
    room: j['room'] as String?,
    profiles: [for (final p in (j['profiles'] as List?) ?? const []) Map<String, dynamic>.from(p as Map)],
    selectedProfile: j['selectedProfile'] as String?,
    ptzPanTilt: j['ptzPanTilt'] == true,
    ptzZoom: j['ptzZoom'] == true,
    presets: [for (final p in (j['presets'] as List?) ?? const []) Map<String, dynamic>.from(p as Map)],
    demoScene: j['demoScene'] as String?,
  );

  /// Brand-neutral [Device], identical in shape to what the hub's
  /// `CameraAdapter` produces, so every screen treats both the same.
  /// Credentials are deliberately absent.
  Device toDevice({required bool reachable}) {
    final selectable = protocol == CameraProtocol.onvif && profiles.length > 1;
    final caps = <String, CapabilityInstance>{
      'videoStream': CapabilityInstance(
        key: 'videoStream',
        actions: selectable ? const ['selectProfile'] : const [],
        state: {
          'protocol': protocol,
          'rtspUrl': rtspUrl,
          'profiles': [
            for (final p in profiles)
              {for (final k in const ['token', 'name', 'width', 'height', 'codec']) k: p[k]},
          ],
          'selectedProfile': selectedProfile,
          'snapshotAvailable': snapshotAvailable,
          'mjpegAvailable': mjpegUrl != null || snapshotUrl != null || demoScene != null,
          'audio': null,
        },
      ),
      if (hasPtz)
        'ptz': CapabilityInstance(
          key: 'ptz',
          actions: ['move', 'stop', if (presets.isNotEmpty) 'gotoPreset'],
          state: {'panTilt': ptzPanTilt, 'zoom': ptzZoom, 'presets': presets},
        ),
      // Demo cameras report readings like the hub's demo cameras, so the Home Summary camera line
      // (visitorCount / motion, see docs/home-summary.md) works in direct mode too.
      if (demoScene != null)
        'sensor': CapabilityInstance(
          key: 'sensor',
          actions: const [],
          state: {
            'readings': {'visitorCount': demoScene == 'door' ? 2 : 0, 'motion': 0},
          },
        ),
    };
    return Device(
      id: id,
      name: name,
      kind: 'camera',
      adapter: 'camera',
      ip: host,
      reachable: reachable,
      controllable: true,
      capabilities: caps,
      meta: {
        'protocol': protocol,
        'model': model,
        'demo': protocol == CameraProtocol.demo,
        if (room != null && room!.isNotEmpty) 'room': room,
      },
    );
  }
}

/// A camera found by ONVIF WS-Discovery (not yet added).
class DiscoveredCamera {
  const DiscoveredCamera({required this.host, this.onvifUrl, this.name, this.hardware, this.added = false});
  final String host;
  final String? onvifUrl, name, hardware;
  final bool added;

  String get label => name ?? hardware ?? host;

  factory DiscoveredCamera.fromJson(Map<String, dynamic> j) => DiscoveredCamera(
    host: j['host'] as String,
    onvifUrl: j['onvifUrl'] as String?,
    name: j['name'] as String?,
    hardware: j['hardware'] as String?,
    added: j['added'] == true,
  );
}

/// What the user typed in the add-camera form.
class NewCamera {
  const NewCamera({
    required this.protocol,
    required this.name,
    this.address = '',
    this.url = '',
    this.username = '',
    this.password = '',
    this.room,
  });
  final String protocol, name, address, url, username, password;
  final String? room;
}

/// Where the pictures of one camera come from. Widgets pick the best available
/// source in this order: RTSP player (native, direct mode) -> MJPEG -> polling
/// [snapshot]. Hub mode never has an [rtspUrl] (the phone must not know the
/// camera's password); it relays through the hub.
abstract class CameraFeed {
  Future<Uint8List> snapshot();

  /// Continuous JPEG frames, or null if there is no MJPEG source.
  Stream<Uint8List>? mjpeg();

  /// RTSP URL **including credentials**, kept in memory only. Null when the
  /// camera has no RTSP stream or the backend relays it instead.
  String? get rtspUrl;

  /// True if [snapshot] can work at all.
  bool get hasSnapshot;
}

/// Optional capability of a [DeviceBackend]: cameras. Screens check
/// `backend is CameraBackend`, so backends without it simply show no camera UI.
abstract class CameraBackend {
  Future<CameraFeed> cameraFeed(String deviceId);
  Future<List<DiscoveredCamera>> discoverCameras();

  /// Adds a camera and returns the created device. Throws BackendException
  /// (400 bad input, 403 wrong camera password, 502 camera unreachable).
  Future<Device> addCamera(NewCamera camera);
  Future<void> removeCamera(String deviceId);

  /// True if this backend can add a `demo` camera (direct mode, bundled sample pictures).
  bool get canAddDemoCamera;
}
