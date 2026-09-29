import '../../models/canonical_catalog.dart';
import '../../models/device.dart';
import '../device_backend.dart';

/// One vendor cloud (SmartThings, LG ThinQ, ...) that the direct-cloud backend
/// aggregates. It mirrors the hub's `CloudAdapter` contract: list devices as
/// canonical [Device]s, refresh one, and execute canonical commands.
abstract class CloudProvider {
  /// Stable id; equals `Device.adapter` of the devices it produces and is the
  /// key used in [DeviceBackend.warnings].
  String get id;

  /// Human label (informational; never used for UI decisions).
  String get name;

  Future<List<Device>> listDevices();

  /// Returns [device] with fresh live state.
  Future<Device> refresh(Device device);

  Future<Map<String, dynamic>> execute(Device device, String capability, String action, Map<String, dynamic> params);

  void close();
}

/// Ports `capabilities.validate_action`: rejects unknown capabilities/actions
/// with a 400 before anything is sent to a vendor.
void validateAction(String capability, String action) {
  final spec = canonicalCatalog[capability];
  if (spec == null) throw BackendException(400, 'unknown capability: $capability');
  if (!spec.actions.containsKey(action)) {
    throw BackendException(
      400,
      "action '$action' not valid for capability '$capability'; valid: ${(spec.actions.keys.toList()..sort())}",
    );
  }
}

/// Vendor safety rule shared by both clouds: laundry only starts remotely
/// after the user pressed "Remote Start" on the machine. `null` = not reported
/// -> allow and let the vendor decide.
void requireRemoteStart(bool? enabled, Device device) {
  if (enabled == false) {
    throw BackendException(
      403,
      "'${device.name}' 기기의 원격 제어가 꺼져 있습니다. 기기에서 '원격 시작' 버튼을 누른 뒤 다시 시도하세요. "
      "(Remote control is disabled on the appliance.)",
    );
  }
}

// ---- small JSON helpers shared by the clients (ports of the Python helpers) ----

Map<String, dynamic> asMap(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<dynamic> asList(Object? v) => v is List ? v : const [];

/// Python `_bool_str`.
bool? boolStr(Object? v) {
  if (v == null) return null;
  if (v is bool) return v;
  final s = v.toString().trim().toLowerCase();
  if (const {'true', 'on', 'open', 'enabled', '1', 'muted'}.contains(s)) return true;
  if (const {'false', 'off', 'closed', 'disabled', '0', 'unmuted'}.contains(s)) return false;
  return null;
}

int intParam(Map<String, dynamic> params, String key, int lo, int hi) {
  final raw = params[key];
  final v = raw is num ? raw.toInt() : int.tryParse('$raw');
  if (v == null) throw BackendException(400, "'$key' must be an integer $lo..$hi");
  if (v < lo || v > hi) throw BackendException(400, "'$key' must be within $lo..$hi");
  return v;
}

num numParam(Map<String, dynamic> params, String key) {
  final raw = params[key];
  final v = raw is num ? raw : num.tryParse('$raw');
  if (v == null || v.isNaN || v.isInfinite) throw BackendException(400, "'$key' must be a number");
  return v == v.truncate() ? v.truncate() : v;
}

bool boolParam(Map<String, dynamic> params, String key) {
  final v = params[key];
  final b = v is bool ? v : boolStr(v);
  if (b == null) throw BackendException(400, "'$key' must be true or false");
  return b;
}

/// The vendor rejected our credentials (401/403): token invalid or expired.
/// Statuscode 401 so the UI shows its "credentials" message; [providerId] tells
/// the settings screen which token to ask for again.
class CloudAuthException extends BackendException {
  const CloudAuthException(this.providerId, String message) : super(401, message);
  final String providerId;
}

/// Supplies the current bearer token (from secure storage). Returns null/empty
/// when the user has not configured one.
typedef TokenSupplier = Future<String?> Function();
