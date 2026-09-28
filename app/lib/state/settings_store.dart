import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/hub_config.dart';

/// Remembers the last hub (address + optional shared secret).
///
/// NOTE: the shared secret is kept in SharedPreferences (NSUserDefaults /
/// Android SharedPreferences). It is a LAN-only dev secret today; move it to
/// the Keychain/Keystore (flutter_secure_storage) once real per-client auth lands.
class SettingsStore {
  SettingsStore(this._prefs);
  final SharedPreferences _prefs;
  static const _kHub = 'lastHub';
  static const _kGroup = 'groupBy';

  HubConfig? loadHub() {
    final raw = _prefs.getString(_kHub);
    if (raw == null) return null;
    try {
      return HubConfig.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveHub(HubConfig c) => _prefs.setString(_kHub, jsonEncode(c.toJson()));
  Future<void> clearHub() => _prefs.remove(_kHub);

  String get groupBy => _prefs.getString(_kGroup) ?? 'kind';
  Future<void> setGroupBy(String v) => _prefs.setString(_kGroup, v);
}
