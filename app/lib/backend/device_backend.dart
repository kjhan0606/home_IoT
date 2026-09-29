import 'dart:async';

import '../models/capability_spec.dart';
import '../models/device.dart';
import '../models/vacuum_map.dart';

/// Where the app gets its devices from. The UI only ever talks to a
/// [DeviceBackend]; it never knows which one is active.
///
///  * [directCloud] - the app calls the vendor clouds itself (default, no server).
///  * [hub]         - the self-hosted HomeHub on the LAN (HTTP + WebSocket).
///  * [relay]       - RESERVED for a future optional paid relay server (push
///                    notifications, Roborock, SmartThings OAuth relay). Not
///                    implemented; see docs/app-backends.md for how to plug it in.
enum BackendKind { directCloud, hub, relay }

/// Error raised by any backend. [statusCode] deliberately reuses the hub's
/// HTTP-style meaning so one error-reporting path serves every backend:
/// 0 network, 400 bad request, 401 credentials rejected, 403 device refused
/// (e.g. appliance remote control is off), 404 unknown device, 501 not
/// supported by this backend, 502 vendor/API failure, 503 not configured.
class BackendException implements Exception {
  const BackendException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  bool get isForbidden => statusCode == 403;
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => '$runtimeType($statusCode): $message';
}

/// Live event pushed by a backend that has an event stream (the hub's `/ws`).
class BackendEvent {
  const BackendEvent(this.type, this.data);
  final String type; // "devices" | "command" | ...
  final Map<String, dynamic> data;
}

/// Everything the app's state and screens need from a source of devices.
/// Devices are brand-neutral [Device]s built from canonical capabilities.
abstract class DeviceBackend {
  BackendKind get kind;

  /// Short label for the app bar, e.g. "직접 연결" or the hub's name.
  String get title;

  /// Secondary line, e.g. "SmartThings · LG ThinQ" or "192.168.0.10:8099".
  String? get subtitle;

  /// True if [events] delivers live updates (hub WebSocket).
  bool get hasEventStream;

  /// If non-null, the app re-reads everything via [sync] this often.
  Duration? get pollInterval;

  /// Per-integration problems from the last sync (id -> Korean message), e.g.
  /// an expired SmartThings token. Empty when everything works.
  Map<String, String> get warnings;

  /// Canonical capability catalog (actions, state schema, uiHint).
  Future<Map<String, CapabilitySpec>> capabilities();

  Future<List<Device>> devices();
  Future<Device> device(String id);

  /// Re-reads one device's live state.
  Future<Device> refresh(String id);

  /// Re-reads every device from the source (pull-to-refresh, polling).
  Future<List<Device>> sync();

  /// Discovers devices ("scan" button). Direct mode = [sync].
  Future<List<Device>> scan({bool lan = true, bool cloud = true});

  /// Sends a canonical command.
  Future<Map<String, dynamic>> command(
    String id,
    String capability,
    String action, [
    Map<String, dynamic> params = const {},
  ]);

  Future<VacuumMap> vacuumMap(String id);

  /// Live events; the stream closes when the connection drops. Only used when
  /// [hasEventStream] is true.
  Stream<BackendEvent> events();

  void close();
}
