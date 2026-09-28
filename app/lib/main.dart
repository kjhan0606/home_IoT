import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/hub_api.dart';
import 'api/hub_discovery.dart';
import 'app.dart';
import 'state/hub_state.dart';
import 'state/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsStore(await SharedPreferences.getInstance());
  final hub = HubState(settings: settings, apiFactory: (c) => HttpHubApi(c));
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: hub),
        Provider<HubDiscovery>(create: (_) => BonsoirHubDiscovery()),
      ],
      child: const HomeIotApp(),
    ),
  );
  hub.reconnectLast(); // remember the last hub
}
