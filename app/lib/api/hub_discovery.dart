import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import '../models/hub_config.dart';

/// Finds hubs advertising `_homehub._tcp` on the LAN (Bonjour/mDNS).
abstract class HubDiscovery {
  bool get supported;

  /// Emits the current list of resolved hubs whenever it changes.
  Stream<List<HubConfig>> discover();
  Future<void> stop();
}

class BonsoirHubDiscovery implements HubDiscovery {
  static const serviceType = '_homehub._tcp';
  BonsoirDiscovery? _discovery;
  StreamController<List<HubConfig>>? _out;

  @override
  bool get supported => !kIsWeb; // browsers cannot do mDNS

  @override
  Stream<List<HubConfig>> discover() {
    _out?.close();
    final out = _out = StreamController<List<HubConfig>>();
    final found = <String, HubConfig>{};
    () async {
      try {
        final d = _discovery = BonsoirDiscovery(type: serviceType);
        await d.initialize();
        d.eventStream!.listen((event) {
          switch (event) {
            case BonsoirDiscoveryServiceFoundEvent():
              event.service.resolve(d.serviceResolver);
            case BonsoirDiscoveryServiceResolvedEvent():
            case BonsoirDiscoveryServiceUpdatedEvent():
              final s = event.service;
              if (s == null) return;
              final host = _pickAddress(s.hostAddresses) ?? s.hostname;
              if (host == null || host.isEmpty) return;
              found[s.name] = HubConfig(host: host, port: s.port, name: s.name);
              if (!out.isClosed) out.add(found.values.toList());
            case BonsoirDiscoveryServiceLostEvent():
              found.remove(event.service.name);
              if (!out.isClosed) out.add(found.values.toList());
            default:
              break;
          }
        });
        await d.start();
      } catch (e) {
        if (!out.isClosed) out.addError(e);
      }
    }();
    return out.stream;
  }

  /// Prefer IPv4 (simplest for http://host:port URLs).
  static String? _pickAddress(List<String> addrs) {
    for (final a in addrs) {
      if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(a)) return a;
    }
    return addrs.isEmpty ? null : addrs.first;
  }

  @override
  Future<void> stop() async {
    try {
      await _discovery?.stop();
    } catch (_) {}
    _discovery = null;
    await _out?.close();
    _out = null;
  }
}
