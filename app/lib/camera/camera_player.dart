import 'package:flutter/widgets.dart';

/// Builds a native RTSP player widget for [url] (may contain credentials) and
/// calls [onError] if playback fails so the caller can fall back to MJPEG /
/// snapshots. Injected from `main.dart` so tests and the web build never load
/// the native player (RTSP does not work in browsers).
typedef RtspViewBuilder = Widget Function(BuildContext context, String url, VoidCallback onError);

class CameraPlayer {
  /// null = no native RTSP player available (web, tests) -> MJPEG / snapshot only.
  static RtspViewBuilder? rtspBuilder;
}
