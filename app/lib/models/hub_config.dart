/// Where the hub is and the optional shared secret (`X-HomeHub-Token`).
class HubConfig {
  const HubConfig({required this.host, this.port = 8099, this.token, this.name});

  final String host;
  final int port;
  final String? token;
  final String? name;

  Uri get baseUri => Uri(scheme: 'http', host: host, port: port);
  Uri get wsUri => Uri(scheme: 'ws', host: host, port: port, path: '/ws');
  String get label => '$host:$port';

  HubConfig copyWith({String? host, int? port, String? token, String? name}) =>
      HubConfig(host: host ?? this.host, port: port ?? this.port, token: token ?? this.token, name: name ?? this.name);

  Map<String, dynamic> toJson() => {'host': host, 'port': port, 'token': token, 'name': name};

  factory HubConfig.fromJson(Map<String, dynamic> j) => HubConfig(
    host: j['host'] as String,
    port: (j['port'] as num?)?.toInt() ?? 8099,
    token: (j['token'] as String?)?.isEmpty == true ? null : j['token'] as String?,
    name: j['name'] as String?,
  );

  /// Parses "host", "host:port" or "http://host:port".
  static HubConfig? parse(String input, {String? token}) {
    var s = input.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) return null;
    final t = token?.trim();
    return HubConfig(host: u.host, port: u.hasPort ? u.port : 8099, token: (t == null || t.isEmpty) ? null : t);
  }
}
