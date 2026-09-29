import 'dart:io';

import 'camera_models.dart';
import 'ws_discovery_io.dart' show wsDiscover;

Future<bool> tcpProbe(String host, int port, {Duration timeout = const Duration(seconds: 2)}) async {
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<List<DiscoveredCamera>> wsDiscoverPlatform({Duration timeout = const Duration(seconds: 3)}) => wsDiscover(timeout: timeout);

const bool platformHasSockets = true;
