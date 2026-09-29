import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../backend/device_backend.dart';
import '../l10n/ko.dart';
import '../state/hub_state.dart';
import '../widgets/capability_view.dart';

/// Detail screen rendered purely from the device's canonical capabilities.
class DeviceDetailScreen extends StatelessWidget {
  const DeviceDetailScreen({super.key, required this.deviceId});
  final String deviceId;

  Future<void> _refresh(BuildContext context) async {
    try {
      await context.read<HubState>().refreshDevice(deviceId);
    } on BackendException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<HubState>();
    final d = hub.device(deviceId);
    if (d == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('기기를 찾을 수 없습니다.')),
      );
    }
    final keys = orderedCapabilities(d);
    return Scaffold(
      appBar: AppBar(
        title: Text(d.name),
        actions: [
          if (d.isExample)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Chip(label: Text(Ko.example), visualDensity: VisualDensity.compact),
            ),
          IconButton(tooltip: '상태 새로고침', onPressed: () => _refresh(context), icon: const Icon(Icons.refresh)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(context),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 4, bottom: 24),
          children: [
            ListTile(
              leading: Icon(Ko.kindIcon(d.kind)),
              title: Text(Ko.kind(d.kind)),
              subtitle: Text(
                [
                  d.reachable ? '온라인' : '오프라인',
                  if (d.room != null) d.room!,
                  if (d.meta['model'] != null) d.meta['model'].toString(),
                ].join(' · '),
              ),
            ),
            if (!d.controllable) const Padding(padding: EdgeInsets.all(16), child: Text('이 기기는 아직 제어를 지원하지 않습니다.')),
            for (final k in keys) capabilityWidget(d, d.capabilities[k]!, hub.specs[k]),
          ],
        ),
      ),
    );
  }
}
