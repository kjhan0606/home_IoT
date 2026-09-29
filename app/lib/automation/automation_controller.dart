import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/hub_api.dart';
import '../backend/device_backend.dart';
import '../backend/direct/direct_cloud_backend.dart';
import '../backend/direct/smartthings_client.dart';
import '../models/automation.dart';
import '../models/device.dart';
import '../state/hub_state.dart';
import 'away.dart';
import 'engine.dart';
import 'rule_store.dart';
import 'st_rules_exporter.dart';

/// Rules for the whole app, one facade over two places they can live:
///
///  * **Hub mode** ([hubManaged] = true): the hub is the always-on rules engine. This controller only
///    edits the hub's rules over its API and shows the hub's run log. Nothing runs in the app.
///  * **Direct-cloud mode**: rules are stored on the phone and evaluated *here*, on every device
///    update and once every [tick] -- but only while the app process is alive and in the foreground
///    (best effort). Reliable unattended automation needs a hub, the premium server, or SmartThings
///    Routines (see docs/home-automation.md).
class AutomationController extends ChangeNotifier {
  AutomationController({
    required this.hub,
    required this.store,
    this.tick = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? hub.now {
    hub.addDevicesListener(_onDevices);
  }

  final HubState hub;
  final RuleStore store;
  final Duration tick;
  final DateTime Function() _now;

  List<Rule> rules = const [];
  List<RunLogEntry> log = const []; // newest first
  Map<String, String> exported = const {}; // ruleId -> SmartThings rule id
  String? error;
  bool loading = false;
  bool _foreground = true;
  bool _disposed = false;
  bool _running = false;
  Timer? _timer;
  final Map<String, String> _lastFired = {};

  // ---- 휴가/장기 외출 모드 ----
  AwayPlan? away;
  bool awayDone = false; // ended/stopped (kept until the user removes it)
  Set<String> _awayOn = {}; // lights the plan turned on (so we only undo our own)
  final Map<String, DateTime> _awayFailed = {};
  Map<String, dynamic>? awayHubStatus; // hub mode: {state, day, days}
  List<Map<String, dynamic>> awaySchedule = const []; // hub mode: today's intervals per light
  static const awayRetry = Duration(minutes: 5);
  final List<String> _events = [];

  bool get hubManaged => hub.api != null;
  HubApi? get _api => hub.api;

  // ------------------------------------------------------------ lifecycle --
  Future<void> load() async {
    loading = true;
    error = null;
    _notify();
    try {
      if (hubManaged) {
        rules = [for (final r in await _api!.automationRules()) Rule.fromJson(r)];
        await _loadAwayFromHub();
        log = [for (final e in await _api!.automationLog()) RunLogEntry.fromJson(e, where: 'hub')];
      } else {
        rules = store.loadRules();
        log = store.loadLog().reversed.toList();
        exported = store.loadExported();
        _loadAwayLocal();
        _lastFired
          ..clear()
          ..addAll(store.loadLastFired());
      }
    } on BackendException catch (e) {
      error = e.message;
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      _notify();
    }
    _restartTimer();
  }

  void setForeground(bool v) {
    if (_foreground == v) return;
    _foreground = v;
    if (v) unawaited(_evaluate(null, hub.devicesById)); // catch up on a time trigger we slept through
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = hubManaged ? null : Timer.periodic(tick, (_) => unawaited(_evaluate(null, hub.devicesById)));
  }

  // ---------------------------------------------------------------- edits --
  Future<void> save(Rule rule) async {
    if (hubManaged) {
      final isNew = !rules.any((r) => r.id == rule.id);
      await _api!.saveAutomationRule(rule.toJson(), id: isNew ? null : rule.id);
      await load();
      return;
    }
    final list = [...rules];
    final i = list.indexWhere((r) => r.id == rule.id);
    i < 0 ? list.add(rule) : list[i] = rule;
    rules = list;
    _markDueAsDone(rule);
    await store.saveRules(rules);
    _notify();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    if (hubManaged) {
      await _api!.setAutomationRuleEnabled(id, enabled);
      await load();
      return;
    }
    final r = rules.firstWhere((r) => r.id == id);
    await save(r.copyWith(enabled: enabled));
  }

  Future<void> delete(String id) async {
    if (hubManaged) {
      await _api!.deleteAutomationRule(id);
      await load();
      return;
    }
    if (exported.containsKey(id)) {
      try {
        await removeFromSamsung(rules.firstWhere((r) => r.id == id));
      } catch (_) {} // still delete locally; the user can remove the Samsung rule in the SmartThings app
    }
    rules = [
      for (final r in rules)
        if (r.id != id) r,
    ];
    _lastFired.remove(id);
    await store.saveRules(rules);
    await store.saveLastFired(_lastFired);
    _notify();
  }

  Future<void> clearLog() async {
    if (hubManaged) {
      await _api!.clearAutomationLog();
    } else {
      await store.saveLog(const []);
    }
    log = const [];
    _notify();
  }

  /// A time rule created or enabled *after* its time today must not fire retroactively.
  void _markDueAsDone(Rule r) {
    if (!r.enabled) return;
    final k = timeKey(r, _now());
    if (k != null) {
      _lastFired[r.id] = k;
      store.saveLastFired(_lastFired);
    }
  }

  /// Sends a named event ('leaving', 'arriving', 'wake', ...). Hub mode: the hub runs the matching
  /// rules; direct mode: they run here, now.
  Future<int> fireEvent(String name) async {
    if (hubManaged) {
      final fired = await _api!.emitAutomationEvent(name);
      await load();
      return fired.length;
    }
    _events.add(name);
    return _evaluate(null, hub.devicesById);
  }

  // ----------------------------------------------------------- local engine --
  void _onDevices(Map<String, Device>? prev, Map<String, Device> cur) {
    // First device list after (re)connecting: fetch the rules/away plan so the home summary can show
    // "휴가 모드 켜짐, 3일째" without the user opening the rules screen first.
    if (prev == null && !loading) unawaited(load());
    if (hubManaged) return;
    unawaited(_evaluate(prev, cur));
  }

  /// One evaluation pass. Returns the number of rules that fired.
  Future<int> _evaluate(Map<String, Device>? prev, Map<String, Device> cur) async {
    if (hubManaged || !_foreground || _disposed || _running) return 0;
    final active = [
      for (final r in rules)
        // rules registered in Samsung's cloud run there; running them here too would double-fire
        if (r.enabled && !exported.containsKey(r.id)) r,
    ];
    final events = List<String>.of(_events);
    _events.clear();
    final awayActive = away != null && !awayDone;
    if ((active.isEmpty && !awayActive) || cur.isEmpty) return 0;
    _running = true;
    try {
      final now = _now();
      final awayRuns = awayActive ? await _awayTick(now, events, cur) : 0;
      if (active.isEmpty) return awayRuns;
      final fires = evaluate(rules: active, prev: prev, cur: cur, now: now, events: events, lastFired: _lastFired);
      final entries = <RunLogEntry>[];
      for (final f in fires) {
        if (f.key != null) _lastFired[f.ruleId] = f.key!;
        entries.add(await _run(f, now));
      }
      if (fires.isNotEmpty) {
        log = [...entries.reversed, ...log];
        if (log.length > RuleStore.maxLog) log = log.sublist(0, RuleStore.maxLog);
        await store.saveLastFired(_lastFired);
        await store.saveLog(log.reversed.toList());
        _notify();
      }
      return fires.length;
    } finally {
      _running = false;
    }
  }

  Future<RunLogEntry> _run(Fire f, DateTime now) async {
    final steps = <RunStep>[];
    for (final s in f.steps) {
      var ok = true;
      String? err;
      if (s.skip == null) {
        try {
          await hub.command(s.deviceId, s.capability, s.action, s.params);
        } on BackendException catch (e) {
          ok = false;
          err = e.message; // one failing device must not stop the rest
        } catch (e) {
          ok = false;
          err = '$e';
        }
      }
      steps.add(
        RunStep(
          deviceId: s.deviceId,
          deviceName: s.deviceName,
          capability: s.capability,
          action: s.action,
          params: s.params,
          skip: s.skip,
          ok: ok,
          error: err,
        ),
      );
    }
    final String status;
    if (steps.isEmpty) {
      status = 'no-targets';
    } else if (steps.every((s) => s.skip != null)) {
      status = 'skipped';
    } else if (steps.any((s) => !s.ok)) {
      status = steps.any((s) => s.ok && s.skip == null) ? 'partial' : 'error';
    } else {
      status = 'ok';
    }
    return RunLogEntry(
      time: now,
      ruleId: f.ruleId,
      ruleName: f.ruleName,
      reason: f.reason,
      status: status,
      steps: steps,
    );
  }

  // ------------------------------------------------ 휴가/장기 외출 모드 --
  Future<void> _loadAwayFromHub() async {
    try {
      final r = await _api!.awayGet();
      final plan = r['plan'];
      away = plan is Map ? AwayPlan.fromJson(Map<String, dynamic>.from(plan)) : null;
      awayHubStatus = r['status'] is Map ? Map<String, dynamic>.from(r['status'] as Map) : null;
      awaySchedule = [for (final e in (r['schedule'] as List?) ?? const []) Map<String, dynamic>.from(e as Map)];
      awayDone = awayHubStatus?['state'] == 'stopped' || awayHubStatus?['state'] == 'finished';
    } on BackendException {
      away = null; // an older hub without the endpoint: the feature is simply not there
      awayHubStatus = null;
    }
    hub.setAway(away, stopped: awayDone);
  }

  void _loadAwayLocal() {
    final raw = store.loadAway();
    away = null;
    awayDone = false;
    _awayOn = {};
    if (raw != null && raw['plan'] is Map) {
      try {
        away = AwayPlan.fromJson(Map<String, dynamic>.from(raw['plan'] as Map));
        awayDone = raw['done'] == true;
        _awayOn = {for (final e in (raw['on'] as List?) ?? const []) '$e'};
      } catch (_) {}
    }
    hub.setAway(away, stopped: awayDone);
  }

  Future<void> _saveAwayLocal() =>
      store.saveAway(away == null ? null : {'plan': away!.toJson(), 'done': awayDone, 'on': _awayOn.toList()..sort()});

  /// Creates/replaces the plan. Throws [FormatException] (Korean message) for an invalid plan.
  Future<void> saveAway(AwayPlan plan) async {
    plan.validate();
    if (hubManaged) {
      await _api!.awaySet(plan.toJson());
      await load();
      return;
    }
    away = plan;
    awayDone = false;
    _awayOn = {};
    _awayFailed.clear();
    await _saveAwayLocal();
    hub.setAway(away);
    _notify();
    await _evaluate(null, hub.devicesById);
  }

  /// "I'm back": turns off what the plan switched on and removes the plan.
  Future<void> stopAway() async {
    if (hubManaged) {
      await _api!.awayStop();
      await load();
      return;
    }
    if (away != null && _awayOn.isNotEmpty) await _awayFinish('휴가 모드 종료', _now(), hub.devicesById);
    away = null;
    awayDone = false;
    _awayOn = {};
    await _saveAwayLocal();
    hub.setAway(null);
    _notify();
  }

  Future<int> _awayTick(DateTime now, List<String> events, Map<String, Device> cur) async {
    final plan = away!;
    if (events.contains('arriving') && plan.endOnArriving) {
      await _awayFinish('휴가 모드 종료', now, cur);
      awayDone = true;
      _awayOn = {};
      await _saveAwayLocal();
      hub.setAway(plan, stopped: true);
      _notify();
      return 1;
    }
    if (awayStatus(plan, now).state == AwayState.finished) {
      final n = await _awayFinish('휴가 모드 끝남', now, cur);
      awayDone = true;
      _awayOn = {};
      await _saveAwayLocal();
      hub.setAway(plan, stopped: true);
      _notify();
      return n;
    }
    final wants = awayWants(plan, now, cur.values);
    return _awayRun(wants, cur, now, wants.isEmpty ? '' : wants.first.reason);
  }

  Future<int> _awayFinish(String reason, DateTime now, Map<String, Device> cur) {
    final wants = [
      for (final id in _awayOn.toList()..sort())
        if (cur.containsKey(id)) AwayWant(id, cur[id]!.name, 'power', 'turnOff', reason),
    ];
    return _awayRun(wants, cur, now, reason);
  }

  /// SAFETY: the away mode may only ever switch lights on/off and open/close curtains.
  Step? _awayStep(AwayWant w, Map<String, Device> cur) {
    final d = cur[w.deviceId];
    if (d == null) return null;
    const allowed = {'power.turnOn', 'power.turnOff', 'curtain.open', 'curtain.close'};
    if (!allowed.contains('${w.capability}.${w.action}')) return null;
    if (w.capability == 'power' && !isAwayLight(d)) return null;
    if (w.capability == 'curtain' && !isAwayCurtain(d)) return null;
    final inst = d.cap(w.capability);
    if (inst == null || !inst.actions.contains(w.action)) return null;
    return Step(
      deviceId: d.id,
      deviceName: d.name,
      capability: w.capability,
      action: w.action,
      skip: alreadyState(d, w.capability, w.action, const {}),
    );
  }

  Future<int> _awayRun(List<AwayWant> wants, Map<String, Device> cur, DateTime now, String reason) async {
    final steps = <Step>[];
    for (final w in wants) {
      final st = _awayStep(w, cur);
      if (st == null) continue;
      if (st.skip != null) {
        if (w.capability == 'power' && w.action == 'turnOn') _awayOn.add(w.deviceId);
        continue;
      }
      final failed = _awayFailed[w.deviceId];
      if (failed != null && now.difference(failed) < awayRetry) continue;
      steps.add(st);
    }
    if (steps.isEmpty) return 0;
    final entry = await _run(Fire(ruleId: 'away', ruleName: '휴가 모드', reason: reason, steps: steps), now);
    for (final r in entry.steps) {
      if (r.ok) {
        _awayFailed.remove(r.deviceId);
        if (r.capability == 'power') r.action == 'turnOn' ? _awayOn.add(r.deviceId) : _awayOn.remove(r.deviceId);
      } else {
        _awayFailed[r.deviceId] = now;
      }
    }
    log = [entry, ...log];
    if (log.length > RuleStore.maxLog) log = log.sublist(0, RuleStore.maxLog);
    await store.saveLog(log.reversed.toList());
    await _saveAwayLocal();
    _notify();
    return 1;
  }

  /// For tests: run one evaluation with explicit snapshots.
  @visibleForTesting
  Future<int> evaluateNow(Map<String, Device>? prev, Map<String, Device> cur) => _evaluate(prev, cur);

  // ------------------------------------------------ Samsung cloud (Rules API) --
  SmartThingsClient? get _st {
    final b = hub.backend;
    final p = b is DirectCloudBackend ? b.provider(SmartThingsClient.providerId) : null;
    return p is SmartThingsClient ? p : null;
  }

  /// Registering in Samsung's cloud is only offered in direct mode with a SmartThings token.
  bool get canExportToSamsung => !hubManaged && _st != null;

  /// What would be registered (throws [StRuleUnsupported] when the rule cannot be expressed).
  Future<StRuleExport> previewSamsung(Rule rule) async {
    final st = _st;
    String? tz;
    if (st != null) {
      try {
        final locs = await st.locations();
        if (locs.length == 1) tz = await st.locationTimeZone('${locs.single['locationId']}');
      } catch (_) {}
    }
    return buildStRule(rule, hub.devices, timeZoneId: tz);
  }

  /// Registers [rule] in the SmartThings cloud. From then on Samsung runs it (app closed, no server
  /// of ours); the app stops evaluating it locally. Throws [StRuleUnsupported] / [BackendException].
  Future<void> registerInSamsung(Rule rule, {String? locationId}) async {
    final st = _st;
    if (st == null) throw const BackendException(503, 'SmartThings 토큰이 설정되지 않았습니다.');
    final locs = await st.locations();
    if (locs.isEmpty) throw const BackendException(404, 'SmartThings 위치를 찾을 수 없습니다.');
    final loc = locationId ?? '${locs.first['locationId']}';
    final tz = await st.locationTimeZone(loc);
    final export = buildStRule(rule, hub.devices, timeZoneId: tz);
    final id = await st.createRule(loc, export.json);
    await setExported(rule.id, '$loc/$id');
  }

  Future<void> removeFromSamsung(Rule rule) async {
    final st = _st;
    final ref = exported[rule.id];
    if (ref == null) return;
    final parts = ref.split('/');
    if (st != null && parts.length == 2) await st.deleteRule(parts[0], parts[1]);
    await setExported(rule.id, null);
  }

  /// Records that a rule was registered in / removed from Samsung's cloud (SmartThings Rules API).
  Future<void> setExported(String ruleId, String? stRuleId) async {
    final m = Map<String, String>.of(exported);
    stRuleId == null ? m.remove(ruleId) : m[ruleId] = stRuleId;
    exported = m;
    await store.saveExported(m);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    hub.removeDevicesListener(_onDevices);
    super.dispose();
  }
}
