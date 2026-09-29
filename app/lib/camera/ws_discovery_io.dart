import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'camera_models.dart';
import 'onvif_client.dart';

/// Multicasts a WS-Discovery probe and collects answers for [timeout]. Never throws
/// (returns an empty list on platforms without UDP, e.g. web).
Future<List<DiscoveredCamera>> wsDiscover({Duration timeout = const Duration(seconds: 3)}) async {
  final found = <String, DiscoveredCamera>{};
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.multicastHops = 2;
    final done = Completer<void>();
    final sub = sock.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = sock!.receive()) != null) {
        for (final c in parseProbeMatches(utf8.decode(d!.data, allowMalformed: true), d.address.address)) {
          found.putIfAbsent(c.host, () => c);
        }
      }
    });
    sock.send(utf8.encode(probeMessage()), InternetAddress('239.255.255.250'), 3702);
    await Future.any([done.future, Future<void>.delayed(timeout)]);
    await sub.cancel();
  } catch (_) {
    // no multicast permission / unsupported platform
  } finally {
    sock?.close();
  }
  return found.values.toList();
}
