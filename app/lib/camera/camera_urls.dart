/// Camera URL helpers (port of the credential helpers in hub/homehub/camera/media.py).
/// Credentials never live inside stored URLs; they are joined in memory at the last moment.
library;

/// `rtsp://u:p@host/x` -> (`rtsp://host/x`, `u`, `p`).
({String url, String? user, String? password}) splitCredentials(String input) {
  final s = input.trim();
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty) throw const FormatException('invalid URL');
  if (u.userInfo.isEmpty) return (url: s, user: null, password: null);
  final parts = u.userInfo.split(':');
  final user = Uri.decodeComponent(parts.first);
  final pw = parts.length > 1 ? Uri.decodeComponent(parts.sublist(1).join(':')) : null;
  final clean = u.replace(userInfo: '').toString().replaceFirst('@', '');
  return (url: clean, user: user.isEmpty ? null : user, password: (pw == null || pw.isEmpty) ? null : pw);
}

String withCredentials(String url, String? user, String? password) {
  if (user == null || user.isEmpty) return url;
  final u = Uri.parse(url);
  final info = Uri.encodeComponent(user) + ((password ?? '').isEmpty ? '' : ':${Uri.encodeComponent(password!)}');
  return u.replace(userInfo: info).toString();
}

/// Hides `user:pass@` in any URL inside [text] (for messages and logs).
String redact(String text) => text.replaceAllMapped(RegExp(r'(\w+://)[^/@\s]+@'), (m) => '${m[1]}***@');

int defaultPort(String url) {
  final u = Uri.parse(url);
  if (u.hasPort) return u.port;
  return switch (u.scheme) {
    'rtsp' => 554,
    'rtsps' => 322,
    'https' => 443,
    _ => 80,
  };
}
