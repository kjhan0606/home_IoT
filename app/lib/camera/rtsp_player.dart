import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Native RTSP playback with media_kit (libmpv + FFmpeg). Only registered on
/// non-web platforms from `main.dart`.
void initRtspPlayer() => MediaKit.ensureInitialized();

Widget mediaKitRtspBuilder(BuildContext context, String url, VoidCallback onError) => _RtspView(url: url, onError: onError);

class _RtspView extends StatefulWidget {
  const _RtspView({required this.url, required this.onError});
  final String url;
  final VoidCallback onError;

  @override
  State<_RtspView> createState() => _RtspViewState();
}

class _RtspViewState extends State<_RtspView> {
  late final Player _player = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error));
  late final VideoController _controller = VideoController(_player);
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      // TCP is far more reliable than UDP through home Wi-Fi; low latency profile for live view.
      final p = _player.platform as dynamic;
      await p.setProperty('rtsp_transport', 'tcp');
      await p.setProperty('profile', 'low-latency');
      await p.setProperty('cache', 'no');
      await p.setProperty('demuxer-lavf-o', 'timeout=8000000');
    } catch (_) {
      // property names differ per platform build; playback still works with defaults
    }
    _player.stream.error.listen((_) => _fail());
    _player.stream.completed.listen((done) {
      if (done) _fail();
    });
    try {
      await _player.setVolume(0);
      await _player.open(Media(widget.url));
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    if (_failed || !mounted) return;
    _failed = true;
    widget.onError();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Video(controller: _controller, controls: NoVideoControls, fill: Colors.black);
}
