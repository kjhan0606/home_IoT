import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/device.dart';
import '../state/hub_state.dart';
import 'home_summary.dart';

/// Where notification text goes. The real one is [LocalNotificationSink]; tests use a fake.
abstract class NotificationSink {
  /// Asks the OS for permission (iOS / Android 13+). Returns whether notifications are allowed.
  Future<bool> requestPermission();
  Future<void> show({required String title, required String body});
}

/// Local notifications through `flutter_local_notifications`.
///
/// LIMIT: these are raised by the app itself, so they only appear while the app process is running
/// (foreground, or recently backgrounded before the OS suspends it). True background push ("your
/// washer finished" while the app is closed) needs a server that watches the devices and sends
/// APNs/FCM -- the premium relay (docs/home-summary.md).
class LocalNotificationSink implements NotificationSink {
  LocalNotificationSink([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;
  int _id = 0;

  Future<void> _init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _ready = true;
  }

  @override
  Future<bool> requestPermission() async {
    try {
      await _init();
      final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) return await ios.requestPermissions(alert: true, badge: false, sound: true) ?? false;
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) return await android.requestNotificationsPermission() ?? false;
      return true;
    } catch (e) {
      debugPrint('notification permission failed: $e');
      return false;
    }
  }

  @override
  Future<void> show({required String title, required String body}) async {
    try {
      await _init();
      await _plugin.show(
        id: _id++ % 1000,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'home_summary',
            '집 요약',
            channelDescription: '세탁 완료, 문 열림 등 집 상태 알림',
            importance: Importance.defaultImportance,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('notification failed: $e');
    }
  }
}

/// Watches the device list and raises a local notification, carrying the one-line summary, when a
/// **new** "needs attention" item appears (laundry finished, fridge door left open, robot needs
/// charging, visitors at the camera, ...). An item notifies once; it can notify again only after it
/// went away and came back. The first load after connecting only records the state (no flood).
class SummaryNotifier {
  SummaryNotifier({required this.hub, required this.sink, this.enabled = true}) {
    hub.addDevicesListener(_onDevices);
  }

  final HubState hub;
  final NotificationSink sink;
  bool enabled;
  final Set<String> _notified = {};

  /// Last notification text (for the UI / tests).
  String? lastBody;

  void _onDevices(Map<String, Device>? prev, Map<String, Device> cur) {
    final summary = buildHomeSummary(cur.values.toList(), now: hub.now(), tracker: hub.summaryTracker);
    final keys = summary.attention.map((i) => i.key).toSet();
    _notified.retainAll(keys); // gone -> may notify again later
    final fresh = summary.attention.where((i) => !_notified.contains(i.key)).toList();
    _notified.addAll(keys);
    if (prev == null || !enabled || fresh.isEmpty) return;
    // Body = the one-line summary of everything needing attention; title = what is new.
    final body = summary.oneLine();
    lastBody = body;
    sink.show(title: fresh.length == 1 ? fresh.first.title : '집 알림 ${fresh.length}건', body: body);
  }

  void dispose() => hub.removeDevicesListener(_onDevices);
}
