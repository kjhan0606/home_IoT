import 'dart:convert';

import '../state/credentials_store.dart';
import 'camera_models.dart';

/// Cameras added in direct mode. The whole list (including camera passwords)
/// is one JSON blob in the same secure storage as the cloud tokens
/// (iOS Keychain / Android Keystore), never in SharedPreferences.
class CameraStore {
  CameraStore(this._store);
  final SecretStore _store;
  static const key = 'cameras_v1';

  Future<List<CameraConfig>> list() async {
    final raw = await _store.read(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [for (final j in jsonDecode(raw) as List) CameraConfig.fromJson(Map<String, dynamic>.from(j as Map))];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _save(List<CameraConfig> l) =>
      l.isEmpty ? _store.delete(key) : _store.write(key, jsonEncode([for (final c in l) c.toJson()]));

  Future<CameraConfig?> get(String id) async {
    for (final c in await list()) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> put(CameraConfig c) async {
    final l = [...await list()];
    final i = l.indexWhere((e) => e.id == c.id);
    i < 0 ? l.add(c) : l[i] = c;
    await _save(l);
  }

  Future<bool> remove(String id) async {
    final l = [...await list()];
    final n = l.length;
    l.removeWhere((c) => c.id == id);
    await _save(l);
    return l.length != n;
  }
}
