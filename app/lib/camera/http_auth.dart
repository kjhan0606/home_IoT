import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

/// HTTP GET/POST that answers a Basic or Digest (RFC 7616, MD5, qop=auth)
/// challenge. IP cameras use both; the `http` package supports neither.
class AuthHttp {
  AuthHttp(this._client, {this.username = '', this.password = ''});

  final http.Client _client;
  final String username, password;
  int _nc = 0;

  Future<http.StreamedResponse> open(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    Future<http.StreamedResponse> send(Map<String, String> h) {
      final req = http.Request(method, url)..headers.addAll(h);
      if (body != null) req.bodyBytes = body;
      return _client.send(req).timeout(timeout);
    }

    var res = await send(headers);
    if (res.statusCode == 401 && username.isNotEmpty) {
      final challenge = res.headers['www-authenticate'] ?? '';
      await res.stream.drain<void>();
      final auth = _answer(challenge, method, url);
      if (auth != null) res = await send({...headers, 'Authorization': auth});
    }
    return res;
  }

  Future<http.Response> get(Uri url, {Duration timeout = const Duration(seconds: 8)}) async =>
      http.Response.fromStream(await open('GET', url, timeout: timeout));

  String? _answer(String challenge, String method, Uri url) {
    final lower = challenge.toLowerCase();
    if (lower.contains('digest')) {
      final p = _parseParams(challenge.substring(lower.indexOf('digest') + 6));
      final realm = p['realm'] ?? '';
      final nonce = p['nonce'] ?? '';
      final uri = url.hasQuery ? '${url.path}?${url.query}' : (url.path.isEmpty ? '/' : url.path);
      String md5(String s) => crypto.md5.convert(utf8.encode(s)).toString();
      final ha1 = md5('$username:$realm:$password');
      final ha2 = md5('$method:$uri');
      final qop = (p['qop'] ?? '').split(',').map((s) => s.trim()).contains('auth') ? 'auth' : null;
      final cnonce = md5('${DateTime.now().microsecondsSinceEpoch}').substring(0, 16);
      final nc = (++_nc).toRadixString(16).padLeft(8, '0');
      final response = qop == null ? md5('$ha1:$nonce:$ha2') : md5('$ha1:$nonce:$nc:$cnonce:$qop:$ha2');
      return 'Digest username="$username", realm="$realm", nonce="$nonce", uri="$uri", response="$response"'
          '${qop == null ? '' : ', qop=$qop, nc=$nc, cnonce="$cnonce"'}'
          '${p['opaque'] == null ? '' : ', opaque="${p['opaque']}"'}';
    }
    if (lower.contains('basic')) {
      return 'Basic ${base64.encode(utf8.encode('$username:$password'))}';
    }
    return null;
  }

  static Map<String, String> _parseParams(String s) => {
    for (final m in RegExp(r'(\w+)=(?:"([^"]*)"|([^\s,]+))').allMatches(s)) m.group(1)!.toLowerCase(): m.group(2) ?? m.group(3)!,
  };

  void close() => _client.close();
}
