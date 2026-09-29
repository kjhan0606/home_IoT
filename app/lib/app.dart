import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'automation/automation_controller.dart';
import 'l10n/ko.dart';
import 'state/hub_state.dart';
import 'backend/device_backend.dart';
import 'screens/connect_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/device_list_screen.dart';

class HomeIotApp extends StatefulWidget {
  const HomeIotApp({super.key});

  @override
  State<HomeIotApp> createState() => _HomeIotAppState();

  static ThemeData theme(Brightness b) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FED), brightness: b),
  );
}

class _HomeIotAppState extends State<HomeIotApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Polling and the app-side rules only run in the foreground (saves cloud quota; the OS suspends us anyway).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    context.read<HubState?>()?.setForeground(fg);
    context.read<AutomationController?>()?.setForeground(fg);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: Ko.appTitle,
    debugShowCheckedModeBanner: false,
    theme: HomeIotApp.theme(Brightness.light),
    darkTheme: HomeIotApp.theme(Brightness.dark),
    themeMode: ThemeMode.system,
    locale: const Locale('ko'),
    home: const HomeGate(),
  );
}

/// Device list when connected; otherwise onboarding (direct-cloud mode, the
/// default) or the hub connect screen (hub mode).
class HomeGate extends StatelessWidget {
  const HomeGate({super.key});

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<HubState>();
    if (hub.status == HubStatus.connected) return const DeviceListScreen();
    if (hub.status == HubStatus.connecting && hub.backend == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (hub.settings.mode == BackendKind.hub) return ConnectScreen(initial: hub.settings.loadHub());
    return const SetupScreen();
  }
}
