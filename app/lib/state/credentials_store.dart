import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal key/value secret storage so tests can swap the Keychain out.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// iOS Keychain / Android Keystore-backed storage (flutter_secure_storage).
class SecureSecretStore implements SecretStore {
  const SecureSecretStore([
    this._s = const FlutterSecureStorage(
      // Keep tokens on this device only: not synced via iCloud Keychain, not restored to a new phone.
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    ),
  ]);
  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// The user's vendor tokens as stored on the device.
class CloudCredentials {
  const CloudCredentials({
    this.smartThingsToken,
    this.smartThingsSavedAt,
    this.lgToken,
    this.lgCountry = 'KR',
    this.lgClientId,
  });

  final String? smartThingsToken;

  /// When the SmartThings PAT was entered (proxy for its 24 h lifetime).
  final DateTime? smartThingsSavedAt;
  final String? lgToken;
  final String lgCountry;
  final String? lgClientId;

  bool get hasSmartThings => smartThingsToken != null && smartThingsToken!.isNotEmpty;
  bool get hasLg => lgToken != null && lgToken!.isNotEmpty;
  bool get hasAny => hasSmartThings || hasLg;

  /// SmartThings PATs issued after 2024-12-30 last 24 h. We only know when the
  /// token was *entered*, so this is a lower bound on its age.
  static const smartThingsLifetime = Duration(hours: 24);

  Duration? smartThingsAge(DateTime now) => smartThingsSavedAt == null ? null : now.difference(smartThingsSavedAt!);

  bool smartThingsLikelyExpired(DateTime now) {
    final age = smartThingsAge(now);
    return hasSmartThings && age != null && age >= smartThingsLifetime;
  }
}

/// Reads/writes [CloudCredentials] in a [SecretStore] (Keychain in the app).
class CredentialsStore {
  CredentialsStore(this._store, {DateTime Function()? now, Random? random})
    : _now = now ?? DateTime.now,
      _rng = random ?? Random.secure();

  final SecretStore _store;
  final DateTime Function() _now;
  final Random _rng;

  static const kSmartThings = 'smartthings_pat';
  static const kSmartThingsSavedAt = 'smartthings_pat_saved_at';
  static const kLgToken = 'lg_thinq_pat';
  static const kLgCountry = 'lg_thinq_country';
  static const kLgClientId = 'lg_thinq_client_id';

  Future<CloudCredentials> load() async => CloudCredentials(
    smartThingsToken: _clean(await _store.read(kSmartThings)),
    smartThingsSavedAt: DateTime.tryParse(await _store.read(kSmartThingsSavedAt) ?? ''),
    lgToken: _clean(await _store.read(kLgToken)),
    lgCountry: _clean(await _store.read(kLgCountry))?.toUpperCase() ?? 'KR',
    lgClientId: _clean(await _store.read(kLgClientId)),
  );

  /// Token suppliers for the clients: always the *current* stored value.
  Future<String?> smartThingsToken() async => _clean(await _store.read(kSmartThings));
  Future<String?> lgToken() async => _clean(await _store.read(kLgToken));

  static String? _clean(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  Future<void> saveSmartThings(String token) async {
    await _store.write(kSmartThings, token.trim());
    await _store.write(kSmartThingsSavedAt, _now().toUtc().toIso8601String());
  }

  Future<void> clearSmartThings() async {
    await _store.delete(kSmartThings);
    await _store.delete(kSmartThingsSavedAt);
  }

  Future<void> saveLg(String token, String country) async {
    await _store.write(kLgToken, token.trim());
    final c = country.trim().toUpperCase();
    await _store.write(kLgCountry, c.isEmpty ? 'KR' : c);
  }

  Future<void> clearLg() async {
    await _store.delete(kLgToken);
    await _store.delete(kLgCountry);
  }

  /// LG expects a stable client id per install; generated once, kept in secure storage.
  Future<String> lgClientId() async {
    final existing = _clean(await _store.read(kLgClientId));
    if (existing != null) return existing;
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    final id = 'homeiot-${b.map((x) => x.toRadixString(16).padLeft(2, '0')).join()}';
    await _store.write(kLgClientId, id);
    return id;
  }

  Future<void> clearAll() async {
    await clearSmartThings();
    await clearLg();
  }
}
