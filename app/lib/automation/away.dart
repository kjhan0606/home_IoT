import '../models/device.dart';
import 'engine.dart' show parseHhmm;

/// 휴가/장기 외출 모드 -- Dart port of `hub/homehub/automation/away.py` (read that file for the design).
///
/// Pure functions, no clock. Both ports run `test/fixtures/away_scenarios.json`, and the random
/// generator is an integer-only Park-Miller so the same seed gives the same evenings in Python and Dart.
///
/// SAFETY: only lights (`kind == 'light'` + `power`) and devices with the `curtain` capability are ever
/// selected, and only turnOn/turnOff/open/close are produced -- never heating, appliances or locks.
const awayMaxDays = 60;
const _m = 2147483647;
const _a = 48271;

const _roomKeywords = <String, List<String>>{
  'living': ['거실', 'living'],
  'bath': ['욕실', '화장실', 'bath', 'toilet', 'wc'],
  'kitchen': ['주방', '부엌', 'kitchen', '다이닝', 'dining'],
  'bedroom': ['침실', '안방', 'bed', '방'],
  'entrance': ['현관', 'entr', 'porch', 'front'],
};

class AwayCurtains {
  const AwayCurtains({
    this.enabled = false,
    this.openAt = '08:00',
    this.closeAt = '18:30',
    this.rooms = const [],
    this.devices = const [],
  });
  final bool enabled;
  final String openAt, closeAt;
  final List<String> rooms, devices;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'openAt': openAt,
    'closeAt': closeAt,
    'rooms': rooms,
    'devices': devices,
  };
  factory AwayCurtains.fromJson(Object? j) {
    final m = j is Map ? j : const {};
    List<String> l(String k) => [for (final e in (m[k] as List?) ?? const []) '$e'];
    return AwayCurtains(
      enabled: m['enabled'] == true,
      openAt: (m['openAt'] as String?) ?? '08:00',
      closeAt: (m['closeAt'] as String?) ?? '18:30',
      rooms: l('rooms'),
      devices: l('devices'),
    );
  }
}

class AwayPlan {
  const AwayPlan({
    required this.startDate,
    required this.endDate,
    this.mode = 'random',
    this.seed = 1,
    this.windowStart = '18:30',
    this.windowEnd = '23:00',
    this.lightRooms = const [],
    this.lightDevices = const [],
    this.curtains = const AwayCurtains(),
    this.enabled = true,
    this.endOnArriving = true,
  });

  final String startDate, endDate; // YYYY-MM-DD
  final String mode; // fixed | random
  final int seed;
  final String windowStart, windowEnd;
  final List<String> lightRooms, lightDevices;
  final AwayCurtains curtains;
  final bool enabled, endOnArriving;

  AwayPlan copyWith({bool? enabled}) => AwayPlan(
    startDate: startDate,
    endDate: endDate,
    mode: mode,
    seed: seed,
    windowStart: windowStart,
    windowEnd: windowEnd,
    lightRooms: lightRooms,
    lightDevices: lightDevices,
    curtains: curtains,
    enabled: enabled ?? this.enabled,
    endOnArriving: endOnArriving,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'startDate': startDate,
    'endDate': endDate,
    'mode': mode,
    'seed': seed,
    'windowStart': windowStart,
    'windowEnd': windowEnd,
    'lights': {'rooms': lightRooms, 'devices': lightDevices},
    'curtains': curtains.toJson(),
    'endOnArriving': endOnArriving,
  };

  factory AwayPlan.fromJson(Map<String, dynamic> j) {
    final lights = j['lights'] is Map ? j['lights'] as Map : const {};
    List<String> l(String k) => [for (final e in (lights[k] as List?) ?? const []) '$e'];
    return AwayPlan(
      enabled: j['enabled'] != false,
      startDate: j['startDate'] as String,
      endDate: j['endDate'] as String,
      mode: (j['mode'] as String?) ?? 'random',
      seed: (j['seed'] as num?)?.toInt() ?? 1,
      windowStart: (j['windowStart'] as String?) ?? '18:30',
      windowEnd: (j['windowEnd'] as String?) ?? '23:00',
      lightRooms: l('rooms'),
      lightDevices: l('devices'),
      curtains: AwayCurtains.fromJson(j['curtains']),
      endOnArriving: j['endOnArriving'] != false,
    );
  }

  /// Same rules as the hub's `normalize_plan` (throws [FormatException]).
  void validate() {
    final s = DateTime.tryParse(startDate), e = DateTime.tryParse(endDate);
    if (s == null || e == null) throw const FormatException('날짜 형식이 올바르지 않습니다.');
    if (e.isBefore(s)) throw const FormatException('끝나는 날이 시작하는 날보다 빠릅니다.');
    if (e.difference(s).inDays + 1 > awayMaxDays) throw const FormatException('최대 $awayMaxDays일까지 설정할 수 있습니다.');
    if (lightRooms.isEmpty && lightDevices.isEmpty) throw const FormatException('켤 조명이나 방을 하나 이상 고르세요.');
    final w = windowMinutes(this);
    if (w < 60 || w > 960) throw const FormatException('저녁 시간대는 1~16시간이어야 합니다.');
  }
}

int windowMinutes(AwayPlan p) => (parseHhmm(p.windowEnd) - parseHhmm(p.windowStart)) % 1440;

/// Integer-only Park-Miller generator (identical to the Python one).
class AwayRng {
  AwayRng(int seed) : state = seed % (_m - 1) + 1 {
    for (var i = 0; i < 3; i++) {
      next();
    }
  }
  int state;
  int next() => state = state * _a % _m;
  int between(int lo, int hi) => hi <= lo ? lo : lo + (next() - 1) % (hi - lo + 1);
}

int _hash(String s) {
  var h = 0;
  for (final r in s.runes) {
    h = (h * 31 + r) % _m;
  }
  return h;
}

int epochDay(DateTime d) => DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(1970)).inDays;

String roomType(String? room) {
  final r = (room ?? '').toLowerCase();
  for (final kind in const ['living', 'bath', 'kitchen', 'entrance', 'bedroom']) {
    if (_roomKeywords[kind]!.any(r.contains)) return kind;
  }
  return 'other';
}

List<(int, int)> _pattern(String kind, int length, AwayRng rng) {
  var iv = <(int, int)>[];
  switch (kind) {
    case 'living':
      final s = rng.between(0, length ~/ 4 < 60 ? length ~/ 4 : 60);
      final lo = length ~/ 2 > 60 ? length ~/ 2 : 60;
      final hi = length * 3 ~/ 4 > 90 ? length * 3 ~/ 4 : 90;
      final e = s + rng.between(lo, hi);
      iv = [(s, e < length ? e : length)];
    case 'kitchen':
      final s = rng.between(0, length ~/ 3);
      final e = s + rng.between(15, 35);
      iv = [(s, e)];
      if (rng.between(0, 1) == 1) {
        final s2 = e + rng.between(20, 60);
        iv.add((s2, s2 + rng.between(10, 20)));
      }
    case 'bath':
      final n = rng.between(1, 3);
      for (var i = 0; i < n; i++) {
        final lo = length ~/ 4;
        final hi = length - 15 > lo ? length - 15 : lo;
        final s = rng.between(lo, hi);
        iv.add((s, s + rng.between(5, 15)));
      }
    case 'bedroom':
      final s = rng.between(length * 2 ~/ 3, length * 5 ~/ 6);
      iv = [(s, s + rng.between(20, 60))];
    case 'entrance':
      final s = rng.between(0, 20);
      iv = [(s, s + rng.between(30, 90))];
    default:
      final s = rng.between(0, length ~/ 2);
      iv = [(s, s + rng.between(30, 90))];
  }
  final clipped = [for (final (a, b) in iv) (a < 0 ? 0 : a, b > length ? length : b)];
  clipped.sort((x, y) => x.$1 != y.$1 ? x.$1.compareTo(y.$1) : x.$2.compareTo(y.$2));
  final merged = <(int, int)>[];
  for (final (a, b) in clipped) {
    if (b - a < 3) continue;
    if (merged.isNotEmpty && a <= merged.last.$2) {
      final last = merged.last;
      merged[merged.length - 1] = (last.$1, last.$2 > b ? last.$2 : b);
    } else {
      merged.add((a, b));
    }
  }
  return merged;
}

bool isAwayLight(Device d) => d.kind == 'light' && d.has('power') && d.cap('power')!.supports('turnOn');
bool isAwayCurtain(Device d) => d.has('curtain');

List<Device> _pick(Iterable<Device> devices, List<String> rooms, List<String> ids, bool Function(Device) ok, bool all) {
  final sorted = devices.toList()..sort((a, b) => a.id.compareTo(b.id));
  return [
    for (final d in sorted)
      if (d.controllable &&
          ok(d) &&
          (ids.contains(d.id) || rooms.contains(d.meta['room']) || (all && rooms.isEmpty && ids.isEmpty)))
        d,
  ];
}

List<Device> chosenLights(AwayPlan p, Iterable<Device> ds) =>
    _pick(ds, p.lightRooms, p.lightDevices, isAwayLight, false);
List<Device> chosenCurtains(AwayPlan p, Iterable<Device> ds) =>
    p.curtains.enabled ? _pick(ds, p.curtains.rooms, p.curtains.devices, isAwayCurtain, true) : const [];

DateTime _day(String iso) {
  final d = DateTime.parse(iso);
  return DateTime(d.year, d.month, d.day);
}

DateTime _at(DateTime day, int minutes) => DateTime(day.year, day.month, day.day, 0, minutes);
DateTime _dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);

/// When light [id] (in [room]) is on during the window that *starts* on [day].
List<(DateTime, DateTime)> lightIntervals(AwayPlan p, DateTime day, String id, String? room) {
  final length = windowMinutes(p);
  final start = parseHhmm(p.windowStart);
  final List<(int, int)> rel;
  if (p.mode == 'fixed') {
    rel = [(0, length)];
  } else {
    rel = _pattern(roomType(room), length, AwayRng(p.seed * 1000003 + epochDay(day) * 7919 + _hash(id)));
  }
  return [for (final (a, b) in rel) (_at(_dateOnly(day), start + a), _at(_dateOnly(day), start + b))];
}

DateTime awayEndMoment(AwayPlan p) => _at(_day(p.endDate), parseHhmm(p.windowStart) + windowMinutes(p));

enum AwayState { scheduled, active, finished, stopped }

class AwayStatus {
  const AwayStatus(this.state, this.day, this.days);
  final AwayState state;
  final int day, days;
  bool get active => state == AwayState.active;

  /// "휴가 모드 켜짐, 3일째"
  String get title => '휴가 모드 켜짐, $day일째';
}

AwayStatus awayStatus(AwayPlan p, DateTime now) {
  final first = _day(p.startDate), last = _day(p.endDate);
  final days = last.difference(first).inDays + 1;
  if (!now.isBefore(awayEndMoment(p))) return AwayStatus(AwayState.finished, days, days);
  final today = _dateOnly(now);
  if (today.isBefore(first)) return AwayStatus(AwayState.scheduled, 0, days);
  final d = today.difference(first).inDays + 1;
  return AwayStatus(AwayState.active, d > days ? days : d, days);
}

class AwayWant {
  const AwayWant(this.deviceId, this.deviceName, this.capability, this.action, this.reason);
  final String deviceId, deviceName, capability, action, reason;
}

/// The commands that make the home match the plan at [now] (empty when not active).
List<AwayWant> awayWants(AwayPlan p, DateTime now, Iterable<Device> devices) {
  final st = awayStatus(p, now);
  if (!p.enabled || st.state != AwayState.active) return const [];
  final first = _day(p.startDate), last = _day(p.endDate);
  final today = _dateOnly(now);
  final tail = '휴가 모드 ${st.day}일째';
  final out = <AwayWant>[];
  final wstart = parseHhmm(p.windowStart);
  bool inRange(DateTime d) => !d.isBefore(first) && !d.isAfter(last);
  for (final d in chosenLights(p, devices)) {
    if (!d.reachable) continue;
    final room = d.meta['room'] as String?;
    var on = false;
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    for (final day in [yesterday, today]) {
      if (inRange(day)) {
        on = on || lightIntervals(p, day, d.id, room).any((iv) => !now.isBefore(iv.$1) && now.isBefore(iv.$2));
      }
    }
    final beforeFirstWindow = today == first && now.isBefore(_at(today, wstart));
    if (!on && beforeFirstWindow) continue;
    out.add(AwayWant(d.id, d.name, 'power', on ? 'turnOn' : 'turnOff', tail));
  }
  final c = p.curtains;
  if (c.enabled) {
    final openM = parseHhmm(c.openAt), closeM = parseHhmm(c.closeAt);
    for (final d in chosenCurtains(p, devices)) {
      if (!d.reachable) continue;
      var jitter = 0;
      if (p.mode == 'random') {
        jitter = AwayRng(p.seed * 999983 + epochDay(today) * 104729 + _hash(d.id)).between(-15, 15);
      }
      final o = _at(today, openM + jitter), cl = _at(today, closeM + jitter);
      if (!now.isBefore(o) && now.isBefore(cl)) {
        out.add(AwayWant(d.id, d.name, 'curtain', 'open', tail));
      } else if (!now.isBefore(cl) || today.isAfter(first)) {
        out.add(AwayWant(d.id, d.name, 'curtain', 'close', tail));
      }
    }
  }
  return out;
}

/// (light name, "19:15~19:49, 20:26~20:37") for the window that is running or starts next; for the UI.
List<(String, String)> awayPreview(AwayPlan p, Iterable<Device> lights, DateTime now) {
  final first = _day(p.startDate), last = _day(p.endDate);
  final wstart = parseHhmm(p.windowStart);
  final today = DateTime(now.year, now.month, now.day);
  var day = now.isBefore(_at(today, wstart)) ? DateTime(today.year, today.month, today.day - 1) : today;
  if (day.isBefore(first)) day = first;
  if (day.isAfter(last)) day = last;
  String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  return [
    for (final d in chosenLights(p, lights))
      (
        d.name,
        [for (final (a, b) in lightIntervals(p, day, d.id, d.meta['room'] as String?)) '${hm(a)}~${hm(b)}'].join(', '),
      ),
  ];
}
