import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/hub_api.dart';
import 'api/hub_discovery.dart';
import 'app.dart';
import 'camera/camera_player.dart';
import 'camera/rtsp_player.dart';
import 'state/credentials_store.dart';
import 'state/hub_state.dart';
import 'state/settings_store.dart';

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
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: hub),
        Provider<HubDiscovery>(create: (_) => BonsoirHubDiscovery()),
      ],
      child: const HomeIotApp(),
    ),
  );
  hub.start(); // resume the remembered mode (direct cloud by default, or the last hub)
}
