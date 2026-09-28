import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'l10n/ko.dart';
import 'state/hub_state.dart';
import 'screens/connect_screen.dart';
import 'screens/device_list_screen.dart';

class HomeIotApp extends StatelessWidget {
  const HomeIotApp({super.key});

  static ThemeData theme(Brightness b) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FED), brightness: b),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: Ko.appTitle,
    debugShowCheckedModeBanner: false,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    themeMode: ThemeMode.system,
    locale: const Locale('ko'),
    home: const HomeGate(),
  );
}

/// Shows the device list when connected, otherwise the connect screen.
class HomeGate extends StatelessWidget {
  const HomeGate({super.key});

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<HubState>();
    if (hub.status == HubStatus.connected) return const DeviceListScreen();
    if (hub.status == HubStatus.connecting && hub.config == null && hub.settings.loadHub() != null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ConnectScreen(initial: hub.settings.loadHub());
  }
}
