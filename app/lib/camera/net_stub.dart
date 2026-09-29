import 'camera_models.dart';

/// Web / unsupported platforms: browsers cannot open raw sockets, so LAN
/// probing and WS-Discovery are unavailable (the hub does them in hub mode).
Future<bool> tcpProbe(String host, int port, {Duration timeout = const Duration(seconds: 2)}) async => true;

Future<List<DiscoveredCamera>> wsDiscoverPlatform({Duration timeout = const Duration(seconds: 3)}) async => const [];

const bool platformHasSockets = false;
