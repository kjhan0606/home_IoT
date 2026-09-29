import 'package:flutter/material.dart';

/// Korean UI strings and labels for canonical (brand-neutral) vocabulary.
/// Unknown values fall back to the raw hub value, so new adapters/values never
/// need an app change to be displayed.
class Ko {
  static const appTitle = '홈 IoT';
  static const example = '예시 데이터';

  static const _kinds = {
    'tv': 'TV',
    'washer': '세탁기',
    'dryer': '건조기',
    'washer-dryer': '세탁건조기',
    'refrigerator': '냉장고',
    'vacuum': '로봇청소기',
    'light': '조명',
    'switch': '스위치/플러그',
    'lock': '도어락',
    'curtain': '커튼/블라인드',
    'camera': '카메라',
    'speaker': '스피커',
    'air-conditioner': '에어컨',
    'air-purifier': '공기청정기',
    'dishwasher': '식기세척기',
    'oven': '오븐',
    'styler': '스타일러',
    'phone': '휴대폰',
    'phone/private': '휴대폰(비공개 MAC)',
    'router': '공유기',
    'set-top-box': '셋톱박스',
    'cast': '캐스트 기기',
    'airplay': 'AirPlay 기기',
    'printer': '프린터',
    'media': '미디어 기기',
    'sensor': '센서',
    'unknown': '기타',
  };
  static String kind(String k) => _kinds[k] ?? k;

  static IconData kindIcon(String k) => switch (k) {
    'tv' || 'set-top-box' || 'cast' || 'airplay' || 'media' => Icons.tv,
    'washer' || 'washer-dryer' => Icons.local_laundry_service,
    'dryer' => Icons.dry_cleaning,
    'refrigerator' => Icons.kitchen,
    'vacuum' => Icons.cleaning_services,
    'light' => Icons.lightbulb_outline,
    'switch' => Icons.power,
    'lock' => Icons.lock_outline,
    'curtain' => Icons.blinds,
    'camera' => Icons.videocam_outlined,
    'speaker' => Icons.speaker,
    'air-conditioner' => Icons.ac_unit,
    'air-purifier' => Icons.air,
    'phone' || 'phone/private' => Icons.smartphone,
    'router' => Icons.router,
    'printer' => Icons.print,
    _ => Icons.devices_other,
  };

  static const _caps = {
    'power': '전원',
    'volume': '볼륨',
    'channel': '채널',
    'mediaInput': '입력',
    'mediaPlayback': '재생',
    'launchApp': '앱',
    'brightness': '밝기',
    'color': '색상',
    'lock': '잠금',
    'curtain': '커튼',
    'vacuum': '청소',
    'sensor': '센서',
    'washer': '세탁',
    'dryer': '건조',
    'refrigeration': '냉장/냉동',
    'roomCleaning': '방 청소',
    'zoneCleaning': '구역 청소',
    'goTo': '지정 위치 이동',
    'fanSpeed': '흡입력',
    'mopping': '물걸레',
    'consumables': '소모품',
    'cleaningStats': '청소 기록',
    'vacuumMap': '지도',
    'videoStream': '영상',
    'ptz': '카메라 회전/확대',
  };
  static String cap(String k) => _caps[k] ?? k;

  static const _vacStatus = {
    'cleaning': '청소 중',
    'paused': '일시정지',
    'returning': '충전대로 복귀 중',
    'charging': '충전 중',
    'docked': '충전대 대기',
    'moving': '이동 중',
    'idle': '대기',
    'error': '오류',
  };
  static String vacuumStatus(String? s) => s == null ? '-' : (_vacStatus[s] ?? s);

  static const _machine = {'run': '동작 중', 'pause': '일시정지', 'stop': '정지'};
  static String machineState(String? s) => s == null ? '-' : (_machine[s] ?? s);

  static const _job = {
    'none': '없음',
    'wash': '세탁',
    'rinse': '헹굼',
    'spin': '탈수',
    'drying': '건조',
    'cooling': '냉각',
    'finish': '완료',
    'finished': '완료',
    'weightsensing': '무게 감지',
    'delaywash': '예약',
    'airwash': '에어워시',
    'wrinkleprevent': '구김 방지',
  };
  static String jobState(String? s) => s == null ? '-' : (_job[s.toLowerCase()] ?? s);

  static const _levels = {
    'off': '끄기',
    'quiet': '저소음',
    'low': '약',
    'balanced': '표준',
    'medium': '중',
    'standard': '표준',
    'high': '강',
    'turbo': '터보',
    'max': '최대',
    'max_plus': '최대+',
    'deep': '딥',
    'deep_plus': '딥+',
    'fast': '빠르게',
    'gentle': '부드럽게',
    'custom': '사용자 지정',
    'smart_mode': '스마트',
  };
  static String level(String? s) => s == null ? '-' : (_levels[s] ?? s);

  static const _consumables = {
    'mainBrush': '메인 브러시',
    'sideBrush': '사이드 브러시',
    'filter': '필터',
    'sensors': '센서',
    'mopRoller': '물걸레 롤러',
  };
  static String consumable(String id, String? fallback) => _consumables[id] ?? fallback ?? id;

  static const remoteStartHelp =
      "원격 제어가 꺼져 있어 앱에서 시작할 수 없습니다. "
      "기기에서 '원격 시작' 버튼을 누른 뒤 다시 시도하세요.";

  static const _curtain = {
    'open': '열림',
    'closed': '닫힘',
    'opening': '열리는 중',
    'closing': '닫히는 중',
    'partial': '일부 열림',
    'unknown': '알 수 없음',
  };
  static String curtainStatus(String? s) => s == null ? '-' : (_curtain[s] ?? s);

  static String duration(num? seconds) {
    if (seconds == null) return '-';
    final m = (seconds / 60).round();
    return m >= 60 ? '${m ~/ 60}시간 ${m % 60}분' : '$m분';
  }
}
