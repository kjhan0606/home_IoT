import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../backend/device_backend.dart';
import '../models/hub_config.dart';

/// Remembers the chosen backend mode, the last hub (address + optional shared
/// secret) and UI preferences.
///
/// Vendor tokens (SmartThings / LG ThinQ) are NOT here: they live in secure
/// storage (Keychain/Keystore) via `CredentialsStore`.
///
/// NOTE: the hub's shared secret is still kept in SharedPreferences
/// (NSUserDefaults / Android SharedPreferences). It is a LAN-only dev secret;
/// move it to secure storage too if hub auth ever becomes more than that.
class SettingsStore {
  SettingsStore(this._prefs);
  final SharedPreferences _prefs;
  static const _kHub = 'lastHub';
  static const _kGroup = 'groupBy';
  static const _kMode = 'backendMode';
  static const _kNotify = 'notifySummary';

  /// Chosen backend. New installs default to [BackendKind.directCloud] (no
  /// server needed); an install that already remembers a hub keeps using it.
  BackendKind get mode {
    final raw = _prefs.getString(_kMode);
    for (final k in const [BackendKind.directCloud, BackendKind.hub]) {
      if (k.name == raw) return k;
    }
    return loadHub() != null ? BackendKind.hub : BackendKind.directCloud;
  }

  Future<void> setMode(BackendKind m) => _prefs.setString(_kMode, m.name);

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

  /// Local notifications for the home summary (only while the app runs). Default on.
  bool get notifySummary => _prefs.getBool(_kNotify) ?? true;
  Future<void> setNotifySummary(bool v) => _prefs.setBool(_kNotify, v);

  String get groupBy => _prefs.getString(_kGroup) ?? 'kind';
  Future<void> setGroupBy(String v) => _prefs.setString(_kGroup, v);
}
