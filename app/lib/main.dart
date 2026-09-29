import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/hub_api.dart';
import 'api/hub_discovery.dart';
import 'app.dart';
import 'camera/camera_player.dart';
import 'camera/rtsp_player.dart';
import 'automation/automation_controller.dart';
import 'automation/rule_store.dart';
import 'state/credentials_store.dart';
import 'state/hub_state.dart';
import 'state/settings_store.dart';
import 'summary/summary_notifier.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    // Native RTSP live view (media_kit). Web builds fall back to MJPEG / snapshots.
    initRtspPlayer();
    CameraPlayer.rtspBuilder = mediaKitRtspBuilder;
  }
  final settings = SettingsStore(await SharedPreferences.getInstance());
  final hub = HubState(
    settings: settings,
    apiFactory: (c) => HttpHubApi(c),
    credentials: CredentialsStore(const SecureSecretStore()),
  );
  final automation = AutomationController(hub: hub, store: RuleStore(await SharedPreferences.getInstance()));
  final sink = LocalNotificationSink();
  final notifier = SummaryNotifier(hub: hub, sink: sink, enabled: settings.notifySummary);
  if (settings.notifySummary) sink.requestPermission(); // iOS / Android 13+ prompt
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: hub),
        ChangeNotifierProvider.value(value: automation),
        Provider<SummaryNotifier>.value(value: notifier),
        Provider<NotificationSink>.value(value: sink),
        Provider<HubDiscovery>(create: (_) => BonsoirHubDiscovery()),
      ],
      child: const HomeIotApp(),
    ),
  );
  await hub.start(); // resume the remembered mode (direct cloud by default, or the last hub)
  await automation.load();
}
