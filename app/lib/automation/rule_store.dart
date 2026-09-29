import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/automation.dart';

/// Persists the app-side rules, run log and bookkeeping (direct-cloud mode).
/// In hub mode the hub owns all of this and the store is not used.
class RuleStore {
  RuleStore(this._prefs);
  final SharedPreferences _prefs;

  static const _kRules = 'automation.rules';
  static const _kLog = 'automation.log';
  static const _kFired = 'automation.lastFired';
  static const _kExported = 'automation.stExported';
  static const _kAway = 'automation.away';
  static const maxLog = 100;

  List<Rule> loadRules() {
    final out = <Rule>[];
    for (final raw in _prefs.getStringList(_kRules) ?? const <String>[]) {
      try {
        out.add(Rule.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map)));
      } catch (_) {} // a corrupt rule must not take the others down
    }
    return out;
  }

  Future<void> saveRules(List<Rule> rules) =>
      _prefs.setStringList(_kRules, [for (final r in rules) jsonEncode(r.toJson())]);

  List<RunLogEntry> loadLog() {
    final out = <RunLogEntry>[];
    for (final raw in _prefs.getStringList(_kLog) ?? const <String>[]) {
      try {
        out.add(RunLogEntry.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map)));
      } catch (_) {}
    }
    return out;
  }

  Future<void> saveLog(List<RunLogEntry> log) {
    final keep = log.length > maxLog ? log.sublist(log.length - maxLog) : log;
    return _prefs.setStringList(_kLog, [for (final e in keep) jsonEncode(e.toJson())]);
  }

  Map<String, String> loadLastFired() {
    final raw = _prefs.getString(_kFired);
    if (raw == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> saveLastFired(Map<String, String> m) => _prefs.setString(_kFired, jsonEncode(m));

  /// ruleId -> SmartThings rule id, for rules that were also registered in Samsung's cloud.
  Map<String, String> loadExported() {
    final raw = _prefs.getString(_kExported);
    if (raw == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> saveExported(Map<String, String> m) => _prefs.setString(_kExported, jsonEncode(m));

  /// The one 휴가 모드 plan plus its bookkeeping: {plan, done, on:[lightIds the plan turned on]}.
  Map<String, dynamic>? loadAway() {
    final raw = _prefs.getString(_kAway);
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveAway(Map<String, dynamic>? v) =>
      v == null ? _prefs.remove(_kAway) : _prefs.setString(_kAway, jsonEncode(v));
}
