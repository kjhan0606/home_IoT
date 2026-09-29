import '../automation/away.dart';
import '../l10n/ko.dart';
import '../models/device.dart';

/// Brand-neutral "whole home" summary engine.
///
/// Input: canonical [Device]s (from any backend: direct cloud or hub). Output: prioritized cards
/// (needs attention / in progress / all good) and a one-line Korean text for notifications.
/// It only reads canonical capabilities (`washer`, `dryer`, `refrigeration`, `vacuum`, `lock`,
/// `curtain`, `power` on lights, `sensor`), never a brand. A category whose capability does not
/// exist in the home (e.g. no camera) simply produces no card.
///
/// Camera contract (the CCTV branch fills it in): a device with `kind == 'camera'` (or a
/// `videoStream` capability) that has a `sensor` capability whose `readings` contain
/// `visitorCount` (people seen at the door recently) and/or `motion` (1 = motion now).
enum SummaryLevel { attention, progress, ok }

class SummaryItem {
  const SummaryItem({
    required this.key,
    required this.level,
    required this.icon,
    required this.title,
    this.detail,
    this.deviceId,
    this.rank = 9,
  });

  /// Stable key (`kind:deviceId`) used to detect new items for notifications.
  final String key;
  final SummaryLevel level;
  final SummaryIcon icon;

  /// Short text used in the one-line summary, e.g. "냉장고 문 열림 12분".
  final String title;

  /// Longer line for the card, e.g. the device name.
  final String? detail;
  final String? deviceId;

  /// Sort rank inside a level (lower = more important).
  final int rank;
}

enum SummaryIcon { away, laundry, fridge, vacuum, camera, lock, light, curtain, offline, tv, device }

class HomeSummary {
  const HomeSummary(this.items);

  final List<SummaryItem> items;

  List<SummaryItem> level(SummaryLevel l) => [
    for (final i in items)
      if (i.level == l) i,
  ];
  List<SummaryItem> get attention => level(SummaryLevel.attention);
  List<SummaryItem> get progress => level(SummaryLevel.progress);
  List<SummaryItem> get ok => level(SummaryLevel.ok);
  bool get isEmpty => items.isEmpty;

  /// One line for the notification / home card, e.g.
  /// "세탁 끝남, 냉장고 문 열림 12분, 로봇청소기 충전 필요, 현관 카메라 방문자 2명".
  /// Only "needs attention" items count; with none, the running activities; with none, all good.
  String oneLine({int max = 4}) {
    List<SummaryItem> pick;
    if (attention.isNotEmpty) {
      pick = attention;
    } else if (progress.isNotEmpty) {
      pick = progress;
    } else {
      return isEmpty ? '표시할 기기가 없습니다' : '집 안 모두 정상입니다';
    }
    final shown = pick.take(max).map((i) => i.title).toList();
    final more = pick.length - shown.length;
    return shown.join(', ') + (more > 0 ? ' 외 $more건' : '');
  }
}

/// Remembers *when* a condition was first seen, for things vendors do not timestamp
/// (door open duration, a laundry cycle that ended while the app was open).
/// Fed with every device sync; feed it the same clock you pass to [buildHomeSummary].
class SummaryTracker {
  final Map<String, DateTime> _since = {};
  final Map<String, String> _lastLaundry = {};

  /// First time [key] was observed true, or null.
  DateTime? since(String key) => _since[key];

  void update(Iterable<Device> devices, DateTime now) {
    final live = <String>{};
    void mark(String key, bool on) {
      if (on) {
        live.add(key);
        _since.putIfAbsent(key, () => now);
      }
    }

    for (final d in devices) {
      final fr = d.cap('refrigeration');
      if (fr != null) mark('door:${d.id}', fr.state['doorOpen'] == true);
      for (final k in const ['washer', 'dryer']) {
        final c = d.cap(k);
        if (c == null) continue;
        final id = '$k:${d.id}';
        final m = c.state['machineState']?.toString();
        final prev = _lastLaundry[id];
        if (m == 'stop' && (prev == 'run' || prev == 'pause')) _since.putIfAbsent('done:$id', () => now);
        if (m == 'run' || m == 'pause') _since.remove('done:$id');
        if (m != null) _lastLaundry[id] = m;
        if (_since.containsKey('done:$id')) live.add('done:$id');
      }
    }
    _since.removeWhere((k, _) => !live.contains(k));
  }
}

/// A finished laundry cycle counts as "just finished" for this long.
const laundryDoneWindow = Duration(hours: 6);

/// Battery at or below this (and not on the dock) needs charging.
const lowBatteryPercent = 20;

String _clean(String name) => name.replaceAll(RegExp(r'\s*\(예시\)\s*$'), '').trim();

String minutesText(Duration d) {
  final m = d.inMinutes;
  if (m < 1) return '방금';
  if (m < 60) return '$m분';
  final h = m ~/ 60;
  return m % 60 == 0 ? '$h시간' : '$h시간 ${m % 60}분';
}

DateTime? _parseTime(Object? v) {
  if (v is! String || v.isEmpty) return null;
  var s = v.trim();
  if (!RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(s)) s = '${s}Z'; // naive = UTC (like the hub)
  return DateTime.tryParse(s);
}

HomeSummary buildHomeSummary(List<Device> devices, {required DateTime now, SummaryTracker? tracker, AwayPlan? away}) {
  final ds = [
    for (final d in devices)
      if (d.controllable || d.capabilities.isNotEmpty) d,
  ];
  final items = <SummaryItem>[];
  final kindCount = <String, int>{};
  for (final d in ds) {
    kindCount[d.kind] = (kindCount[d.kind] ?? 0) + 1;
  }

  // "냉장고" when it is the only one of its kind, otherwise the device's own name.
  String label(Device d) {
    if (d.kind == 'camera') return _clean(d.name);
    return kindCount[d.kind] == 1 && d.kind != 'unknown' ? Ko.kind(d.kind) : _clean(d.name);
  }

  void add(SummaryItem i) => items.add(i);

  var offline = 0;
  final lightsOn = <Device>[];
  var lights = 0;
  final curtains = <Device>[];

  for (final d in ds) {
    if (d.controllable && !d.reachable) {
      offline++;
      continue;
    }

    // ---- laundry ----------------------------------------------------------
    for (final (key, noun) in const [('washer', '세탁'), ('dryer', '건조')]) {
      final c = d.cap(key);
      if (c == null) continue;
      final m = c.state['machineState']?.toString();
      final id = '$key:${d.id}';
      final who = _clean(d.name);
      if (m == 'run' || m == 'pause') {
        final rem = c.number('remainingMinutes');
        final title = m == 'pause' ? '$noun 일시정지' : '$noun 중${rem != null && rem > 0 ? ' ${rem.round()}분 남음' : ''}';
        add(
          SummaryItem(
            key: 'progress:$id',
            level: SummaryLevel.progress,
            icon: SummaryIcon.laundry,
            title: title,
            detail: who,
            deviceId: d.id,
            rank: 1,
          ),
        );
      } else if (m == 'stop') {
        final completed = _parseTime(c.state['completionTime']);
        final seen = tracker?.since('done:$id');
        DateTime? doneAt;
        if (completed != null &&
            !completed.isAfter(now.add(const Duration(minutes: 2))) &&
            now.difference(completed) <= laundryDoneWindow) {
          doneAt = completed;
        } else if (seen != null && now.difference(seen) <= laundryDoneWindow) {
          doneAt = seen;
        }
        if (doneAt != null) {
          final ago = now.difference(doneAt);
          add(
            SummaryItem(
              key: 'done:$id',
              level: SummaryLevel.attention,
              icon: SummaryIcon.laundry,
              title: '$noun 끝남',
              detail: '$who · ${minutesText(ago)}${ago.inMinutes < 1 ? '' : ' 전'}',
              deviceId: d.id,
              rank: 1,
            ),
          );
        } else {
          add(
            SummaryItem(
              key: 'idle:$id',
              level: SummaryLevel.ok,
              icon: SummaryIcon.laundry,
              title: '${label(d)} 대기',
              detail: who,
              deviceId: d.id,
              rank: 5,
            ),
          );
        }
      }
    }

    // ---- refrigerator -----------------------------------------------------
    final fr = d.cap('refrigeration');
    if (fr != null) {
      final name = label(d);
      if (fr.state['doorOpen'] == true) {
        final since = _parseTime(fr.state['doorOpenSince']) ?? tracker?.since('door:${d.id}');
        final dur = since == null ? null : now.difference(since);
        add(
          SummaryItem(
            key: 'door:${d.id}',
            level: SummaryLevel.attention,
            icon: SummaryIcon.fridge,
            title: '$name 문 열림${dur == null ? '' : ' ${minutesText(dur)}'}',
            detail: dur == null ? _clean(d.name) : '${_clean(d.name)} · ${minutesText(dur)}째 열려 있음',
            deviceId: d.id,
            rank: 2,
          ),
        );
      } else {
        final t = fr.number('fridgeTemperature');
        final unit = fr.state['unit'] ?? 'C';
        final tooWarm = t != null && ((unit == 'F' ? (t - 32) * 5 / 9 : t) >= 10);
        if (tooWarm) {
          add(
            SummaryItem(
              key: 'warm:${d.id}',
              level: SummaryLevel.attention,
              icon: SummaryIcon.fridge,
              title: '$name 온도 높음',
              detail: '냉장 $t°$unit',
              deviceId: d.id,
              rank: 2,
            ),
          );
        } else {
          final parts = [
            if (t != null) '냉장 $t°$unit',
            if (fr.number('freezerTemperature') != null) '냉동 ${fr.number('freezerTemperature')}°$unit',
          ];
          add(
            SummaryItem(
              key: 'fridge-ok:${d.id}',
              level: SummaryLevel.ok,
              icon: SummaryIcon.fridge,
              title: '$name 정상',
              detail: parts.isEmpty ? null : parts.join(' · '),
              deviceId: d.id,
              rank: 3,
            ),
          );
        }
      }
    }

    // ---- robot vacuum -----------------------------------------------------
    final vac = d.cap('vacuum');
    if (vac != null) {
      final name = label(d);
      final status = vac.state['status']?.toString();
      final battery = vac.number('battery')?.round();
      final onDock = status == 'charging' || status == 'docked';
      if (status == 'error') {
        final err = vac.state['error'] ?? vac.state['dockError'];
        add(
          SummaryItem(
            key: 'vac-error:${d.id}',
            level: SummaryLevel.attention,
            icon: SummaryIcon.vacuum,
            title: '$name 오류',
            detail: err == null ? _clean(d.name) : '${_clean(d.name)} · $err',
            deviceId: d.id,
            rank: 3,
          ),
        );
      } else if (battery != null && battery <= lowBatteryPercent && !onDock) {
        add(
          SummaryItem(
            key: 'vac-charge:${d.id}',
            level: SummaryLevel.attention,
            icon: SummaryIcon.vacuum,
            title: '$name 충전 필요',
            detail: '배터리 $battery%',
            deviceId: d.id,
            rank: 3,
          ),
        );
      } else if (status == 'cleaning' || status == 'moving' || status == 'returning' || status == 'paused') {
        final text = switch (status) {
          'returning' => '충전대로 복귀 중',
          'paused' => '일시정지',
          _ => '청소 중',
        };
        add(
          SummaryItem(
            key: 'vac-run:${d.id}',
            level: SummaryLevel.progress,
            icon: SummaryIcon.vacuum,
            title: '$name $text',
            detail: battery == null ? null : '배터리 $battery%',
            deviceId: d.id,
            rank: 3,
          ),
        );
      } else {
        add(
          SummaryItem(
            key: 'vac-ok:${d.id}',
            level: SummaryLevel.ok,
            icon: SummaryIcon.vacuum,
            title: '$name ${Ko.vacuumStatus(status)}',
            detail: battery == null ? null : '배터리 $battery%',
            deviceId: d.id,
            rank: 4,
          ),
        );
      }
    }
    final cons = d.cap('consumables');
    if (cons != null) {
      final worn = [
        for (final it in cons.objects('items'))
          if (it['remainingPercent'] is num && (it['remainingPercent'] as num) <= 10)
            Ko.consumable('${it['id']}', it['name']?.toString()),
      ];
      if (worn.isNotEmpty) {
        add(
          SummaryItem(
            key: 'consumables:${d.id}',
            level: SummaryLevel.attention,
            icon: SummaryIcon.vacuum,
            title: '${label(d)} ${worn.first} 교체 필요',
            detail: worn.join(', '),
            deviceId: d.id,
            rank: 6,
          ),
        );
      }
    }

    // ---- lock -------------------------------------------------------------
    final lock = d.cap('lock');
    if (lock != null) {
      final name = _clean(d.name);
      if (lock.state['locked'] == false) {
        add(
          SummaryItem(
            key: 'unlocked:${d.id}',
            level: SummaryLevel.attention,
            icon: SummaryIcon.lock,
            title: '$name 열림',
            detail: '잠기지 않았습니다',
            deviceId: d.id,
            rank: 0,
          ),
        );
      } else {
        add(
          SummaryItem(
            key: 'locked:${d.id}',
            level: SummaryLevel.ok,
            icon: SummaryIcon.lock,
            title: '$name 잠김',
            deviceId: d.id,
            rank: 2,
          ),
        );
      }
    }

    // ---- camera (only when such a device exists) ----------------------------
    if (d.kind == 'camera' || d.has('videoStream')) {
      final readings = d.cap('sensor')?.state['readings'];
      final r = readings is Map ? readings : const {};
      final visitors = r['visitorCount'] is num ? (r['visitorCount'] as num).round() : 0;
      final motion = r['motion'] is num && (r['motion'] as num) > 0;
      final name = _clean(d.name);
      if (visitors > 0) {
        add(
          SummaryItem(
            key: 'visitors:${d.id}',
            level: SummaryLevel.attention,
            icon: SummaryIcon.camera,
            title: '$name 방문자 $visitors명',
            detail: '카메라에서 사람이 감지되었습니다',
            deviceId: d.id,
            rank: 4,
          ),
        );
      } else if (motion) {
        add(
          SummaryItem(
            key: 'motion:${d.id}',
            level: SummaryLevel.attention,
            icon: SummaryIcon.camera,
            title: '$name 움직임 감지',
            deviceId: d.id,
            rank: 4,
          ),
        );
      } else {
        add(
          SummaryItem(
            key: 'cam-ok:${d.id}',
            level: SummaryLevel.ok,
            icon: SummaryIcon.camera,
            title: '$name 이상 없음',
            deviceId: d.id,
            rank: 5,
          ),
        );
      }
    }

    // ---- lights / curtains / tv ---------------------------------------------
    if (d.kind == 'light' && d.has('power')) {
      lights++;
      if (d.powerOn == true) lightsOn.add(d);
    }
    if (d.has('curtain')) curtains.add(d);
    if (d.kind == 'tv' && d.powerOn == true) {
      add(
        SummaryItem(
          key: 'tv-on:${d.id}',
          level: SummaryLevel.progress,
          icon: SummaryIcon.tv,
          title: '${label(d)} 켜짐',
          detail: _clean(d.name),
          deviceId: d.id,
          rank: 8,
        ),
      );
    }
  }

  if (offline > 0) {
    add(
      SummaryItem(
        key: 'offline',
        level: SummaryLevel.attention,
        icon: SummaryIcon.offline,
        title: '오프라인 기기 $offline개',
        detail: '전원이나 Wi-Fi를 확인하세요',
        rank: 7,
      ),
    );
  }
  if (lights > 0) {
    if (lightsOn.isEmpty) {
      add(
        const SummaryItem(key: 'lights', level: SummaryLevel.ok, icon: SummaryIcon.light, title: '조명 모두 꺼짐', rank: 6),
      );
    } else {
      add(
        SummaryItem(
          key: 'lights',
          level: SummaryLevel.progress,
          icon: SummaryIcon.light,
          title: '조명 ${lightsOn.length}개 켜짐',
          detail: lightsOn.map((d) => _clean(d.name)).join(', '),
          rank: 9,
        ),
      );
    }
  }
  if (curtains.isNotEmpty) {
    final closed = curtains.where((d) => d.cap('curtain')!.state['status'] == 'closed').length;
    final open = curtains.where((d) => d.cap('curtain')!.state['status'] == 'open').length;
    final text = closed == curtains.length
        ? '커튼 모두 닫힘'
        : open == curtains.length
        ? '커튼 모두 열림'
        : '커튼 ${curtains.length}개 (닫힘 $closed · 열림 $open)';
    add(SummaryItem(key: 'curtains', level: SummaryLevel.ok, icon: SummaryIcon.curtain, title: text, rank: 7));
  }

  if (away != null && away.enabled) {
    final st = awayStatus(away, now);
    if (st.state == AwayState.active) {
      add(
        SummaryItem(
          key: 'away',
          level: SummaryLevel.progress,
          icon: SummaryIcon.away,
          title: st.title,
          detail:
              '${away.endDate.substring(5).replaceFirst('-', '/')}까지 · ${away.mode == 'random' ? '무작위 점등' : '정해진 시간 점등'}',
          rank: 0,
        ),
      );
    } else if (st.state == AwayState.scheduled) {
      add(
        SummaryItem(
          key: 'away-scheduled',
          level: SummaryLevel.ok,
          icon: SummaryIcon.away,
          title: '휴가 모드 예약됨',
          detail: '${away.startDate.substring(5).replaceFirst('-', '/')}부터',
          rank: 0,
        ),
      );
    }
  }

  items.sort((a, b) {
    final l = a.level.index.compareTo(b.level.index);
    return l != 0 ? l : a.rank.compareTo(b.rank);
  });
  return HomeSummary(items);
}
