import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../backend/device_backend.dart';
import '../camera/camera_models.dart';
import '../models/device.dart';
import '../screens/camera_screen.dart';
import '../state/hub_state.dart';

/// Grid of camera tiles for the device list (2 columns). Tiles show a still
/// picture that refreshes slowly (cheap); tap for the live page.
class CameraGrid extends StatelessWidget {
  const CameraGrid({super.key, required this.cameras});
  final List<Device> cameras;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: GridView.count(
      key: const Key('camera-grid'),
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 4 / 3,
      children: [for (final c in cameras) CameraThumb(device: c)],
    ),
  );
}

class CameraThumb extends StatefulWidget {
  const CameraThumb({super.key, required this.device, this.refresh = const Duration(seconds: 15)});
  final Device device;
  final Duration refresh;

  @override
  State<CameraThumb> createState() => _CameraThumbState();
}

class _CameraThumbState extends State<CameraThumb> {
  Uint8List? _img;
  bool _failed = false;
  Timer? _timer;
  CameraFeed? _feed;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(widget.refresh, (_) => _load());
  }

  Future<void> _load() async {
    final b = context.read<HubState>().backend;
    if (b is! CameraBackend || !widget.device.reachable) return;
    try {
      _feed ??= await (b as CameraBackend).cameraFeed(widget.device.id);
      if (!_feed!.hasSnapshot) return;
      final img = await _feed!.snapshot();
      if (mounted) {
        setState(() {
          _img = img;
          _failed = false;
        });
      }
    } on BackendException {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final cs = Theme.of(context).colorScheme;
    return Material(
      key: Key('device-${d.id}'),
      color: Colors.black,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CameraScreen(deviceId: d.id))),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_img != null)
              Image.memory(_img!, fit: BoxFit.cover, gaplessPlayback: true)
            else
              Center(
                child: Icon(
                  d.reachable ? Icons.videocam_outlined : Icons.videocam_off_outlined,
                  size: 36,
                  color: _failed ? cs.error : Colors.white54,
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                color: Colors.black54,
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 8, color: d.reachable ? Colors.green : Colors.grey),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                    if (d.has('ptz')) const Icon(Icons.open_with, size: 14, color: Colors.white70),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
