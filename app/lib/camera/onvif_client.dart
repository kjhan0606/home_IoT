import 'dart:async';
import 'dart:convert';
import 'dart:math';
import "dart:typed_data";

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../backend/device_backend.dart';
import 'camera_models.dart';

/// Dart port of `hub/homehub/camera/onvif.py`: minimal ONVIF (SOAP over HTTP,
/// WS-Security UsernameToken *PasswordDigest*) plus WS-Discovery. Used in direct
/// mode, where the phone talks to the camera itself on the LAN.
///
/// Errors are [BackendException]s with the hub's meaning: 403 = the camera
/// rejected the user name/password, 502 = camera unreachable / bad answer.
class OnvifClient {
  OnvifClient(this.deviceUrl, {this.username = '', this.password = '', http.Client? client, Random? random, DateTime Function()? now})
    : _http = client ?? http.Client(),
      _rng = random ?? Random.secure(),
      _now = now ?? DateTime.now;

  final String deviceUrl, username, password;
  final http.Client _http;
  final Random _rng;
  final DateTime Function() _now;
  Duration _clockOffset = Duration.zero;
  bool _clockSynced = false;
  String? mediaUrl, ptzUrl;

  static const nsEnv = 'http://www.w3.org/2003/05/soap-envelope';
  static const nsDevice = 'http://www.onvif.org/ver10/device/wsdl';
  static const nsMedia = 'http://www.onvif.org/ver10/media/wsdl';
  static const nsPtz = 'http://www.onvif.org/ver20/ptz/wsdl';
  static const nsSchema = 'http://www.onvif.org/ver10/schema';
  static const _wsse = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd';
  static const _wsu = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd';
  static const _digestType = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest';
  static const _nonceType = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary';

  static String esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  /// `192.168.0.50` / `192.168.0.50:8080` / full URL -> ONVIF device service URL.
  static String normalizeDeviceUrl(String hostOrUrl) {
    var s = hostOrUrl.trim();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(s)) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) throw const BackendException(400, '카메라 주소가 올바르지 않습니다.');
    if (u.path.isEmpty || u.path == '/') return '${u.scheme}://${u.authority}/onvif/device_service';
    return s;
  }

  String securityHeader() {
    if (username.isEmpty) return '';
    final nonce = Uint8List.fromList(List.generate(16, (_) => _rng.nextInt(256)));
    final created = '${_now().toUtc().add(_clockOffset).toIso8601String().split('.').first}Z';
    final digest = base64.encode(crypto.sha1.convert([...nonce, ...utf8.encode(created), ...utf8.encode(password)]).bytes);
    return '<Security xmlns="$_wsse" xmlns:s="$nsEnv" s:mustUnderstand="1"><UsernameToken>'
        '<Username>${esc(username)}</Username>'
        '<Password Type="$_digestType">$digest</Password>'
        '<Nonce EncodingType="$_nonceType">${base64.encode(nonce)}</Nonce>'
        '<Created xmlns="$_wsu">$created</Created></UsernameToken></Security>';
  }

  Future<XmlDocument> _call(String url, String body, {bool auth = true}) async {
    final header = auth && username.isNotEmpty ? '<s:Header>${securityHeader()}</s:Header>' : '';
    final env =
        '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="$nsEnv" xmlns:tt="$nsSchema" '
        'xmlns:tds="$nsDevice" xmlns:trt="$nsMedia" xmlns:tptz="$nsPtz">$header<s:Body>$body</s:Body></s:Envelope>';
    http.Response r;
    try {
      r = await _http
          .post(Uri.parse(url), headers: {'Content-Type': 'application/soap+xml; charset=utf-8'}, body: utf8.encode(env))
          .timeout(const Duration(seconds: 6));
    } on TimeoutException {
      throw BackendException(502, '카메라(${Uri.parse(url).authority})가 응답하지 않습니다.');
    } catch (_) {
      throw BackendException(502, '카메라(${Uri.parse(url).authority})에 연결할 수 없습니다.');
    }
    if (r.statusCode == 401) throw const BackendException(403, '카메라가 사용자 이름 또는 비밀번호를 거부했습니다.');
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(utf8.decode(r.bodyBytes, allowMalformed: true));
    } catch (_) {
      throw BackendException(502, '카메라가 ONVIF 응답이 아닌 데이터를 보냈습니다 (HTTP ${r.statusCode}).');
    }
    final fault = _first(doc, 'Fault');
    if (fault != null) {
      final reason = _text(fault, 'Text') ?? 'SOAP fault';
      final code = fault.descendants.whereType<XmlElement>().where((e) => e.localName == 'Value').map((e) => e.innerText).join(' ');
      final l = reason.toLowerCase();
      if (code.contains('NotAuthorized') || l.contains('not authorized') || l.contains('unauthorized')) {
        throw const BackendException(403, '카메라가 사용자 이름 또는 비밀번호를 거부했습니다.');
      }
      throw BackendException(502, '카메라 오류: $reason');
    }
    if (r.statusCode >= 400) throw BackendException(502, '카메라가 HTTP ${r.statusCode}로 응답했습니다.');
    return doc;
  }

  static XmlElement? _first(XmlNode n, String local) {
    for (final e in n.descendants.whereType<XmlElement>()) {
      if (e.localName == local) return e;
    }
    return null;
  }

  static Iterable<XmlElement> _all(XmlNode n, String local) => n.descendants.whereType<XmlElement>().where((e) => e.localName == local);

  static String? _text(XmlNode? n, String local) {
    final e = n == null ? null : _first(n, local);
    final t = e?.innerText.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  Future<void> syncClock() async {
    if (_clockSynced) return;
    _clockSynced = true;
    try {
      final doc = await _call(deviceUrl, '<tds:GetSystemDateAndTime/>', auth: false);
      final utc = _first(doc, 'UTCDateTime');
      if (utc == null) return;
      int n(String s) => int.tryParse(_text(utc, s) ?? '') ?? 0;
      final cam = DateTime.utc(n('Year'), n('Month'), n('Day'), n('Hour'), n('Minute'), n('Second'));
      _clockOffset = cam.difference(_now().toUtc());
    } on BackendException {
      // best effort
    }
  }

  Future<Map<String, String?>> deviceInformation() async {
    await syncClock();
    final doc = await _call(deviceUrl, '<tds:GetDeviceInformation/>');
    return {for (final k in const ['Manufacturer', 'Model', 'FirmwareVersion', 'SerialNumber', 'HardwareId']) k: _text(doc, k)};
  }

  Future<void> discoverServices() async {
    await syncClock();
    final doc = await _call(deviceUrl, '<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>');
    final media = _first(doc, 'Media');
    final ptz = _first(doc, 'PTZ');
    mediaUrl = media == null ? null : _text(media, 'XAddr');
    ptzUrl = ptz == null ? null : _text(ptz, 'XAddr');
    if (mediaUrl == null) throw const BackendException(502, '카메라가 ONVIF 미디어 서비스를 제공하지 않습니다.');
  }

  Future<List<Map<String, dynamic>>> profiles() async {
    if (mediaUrl == null) await discoverServices();
    final doc = await _call(mediaUrl!, '<trt:GetProfiles/>');
    final out = <Map<String, dynamic>>[];
    for (final p in _all(doc, 'Profiles')) {
      final token = p.getAttribute('token');
      if (token == null) continue;
      final venc = _first(p, 'VideoEncoderConfiguration');
      final res = venc == null ? null : _first(venc, 'Resolution');
      out.add({
        'token': token,
        'name': _text(p, 'Name') ?? token,
        'codec': venc == null ? null : _text(venc, 'Encoding'),
        'width': res == null ? null : int.tryParse(_text(res, 'Width') ?? ''),
        'height': res == null ? null : int.tryParse(_text(res, 'Height') ?? ''),
        'ptz': _first(p, 'PTZConfiguration') != null,
      });
    }
    if (out.isEmpty) throw const BackendException(502, '카메라에 미디어 프로필이 없습니다.');
    return out;
  }

  Future<String> streamUri(String profile) async {
    final doc = await _call(
      mediaUrl!,
      '<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport>'
      '</trt:StreamSetup><trt:ProfileToken>${esc(profile)}</trt:ProfileToken></trt:GetStreamUri>',
    );
    final uri = _text(doc, 'Uri');
    if (uri == null) throw const BackendException(502, '카메라가 스트림 주소를 알려주지 않았습니다.');
    return uri;
  }

  Future<String?> snapshotUri(String profile) async {
    try {
      final doc = await _call(mediaUrl!, '<trt:GetSnapshotUri><trt:ProfileToken>${esc(profile)}</trt:ProfileToken></trt:GetSnapshotUri>');
      return _text(doc, 'Uri');
    } on BackendException catch (e) {
      if (e.statusCode == 403) rethrow;
      return null; // snapshot is optional in ONVIF
    }
  }

  String _needPtz() {
    if (ptzUrl == null) throw const BackendException(400, '이 카메라는 PTZ(회전/확대)를 지원하지 않습니다.');
    return ptzUrl!;
  }

  Future<void> ptzMove(String profile, double pan, double tilt, double zoom, {double? timeoutSeconds}) async {
    final vel = StringBuffer();
    if (pan != 0 || tilt != 0) vel.write('<tt:PanTilt x="${pan.toStringAsFixed(3)}" y="${tilt.toStringAsFixed(3)}"/>');
    if (zoom != 0) vel.write('<tt:Zoom x="${zoom.toStringAsFixed(3)}"/>');
    final to = timeoutSeconds == null ? '' : '<tptz:Timeout>PT${timeoutSeconds.toStringAsFixed(1)}S</tptz:Timeout>';
    await _call(
      _needPtz(),
      '<tptz:ContinuousMove><tptz:ProfileToken>${esc(profile)}</tptz:ProfileToken><tptz:Velocity>$vel</tptz:Velocity>$to</tptz:ContinuousMove>',
    );
  }

  Future<void> ptzStop(String profile) async => _call(
    _needPtz(),
    '<tptz:Stop><tptz:ProfileToken>${esc(profile)}</tptz:ProfileToken><tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>',
  );

  Future<List<Map<String, dynamic>>> ptzPresets(String profile) async {
    final doc = await _call(_needPtz(), '<tptz:GetPresets><tptz:ProfileToken>${esc(profile)}</tptz:ProfileToken></tptz:GetPresets>');
    return [
      for (final p in _all(doc, 'Preset'))
        if (p.getAttribute('token') != null) {'token': p.getAttribute('token')!, 'name': _text(p, 'Name') ?? p.getAttribute('token')!},
    ];
  }

  Future<void> ptzGotoPreset(String profile, String preset) async => _call(
    _needPtz(),
    '<tptz:GotoPreset><tptz:ProfileToken>${esc(profile)}</tptz:ProfileToken><tptz:PresetToken>${esc(preset)}</tptz:PresetToken></tptz:GotoPreset>',
  );
}

// ------------------------------------------------------------- WS-Discovery ----
String probeMessage([String? id]) =>
    '<?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
    'xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:${id ?? _uuid()}</w:MessageID>'
    '<w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
    '<w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>'
    '<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>';

String _uuid() {
  final r = Random.secure();
  String h(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  return '${h(8)}-${h(4)}-4${h(3)}-a${h(3)}-${h(12)}';
}

/// Parses one ProbeMatches datagram (mirror of the Python `parse_probe_matches`).
List<DiscoveredCamera> parseProbeMatches(String xml, [String? sourceIp]) {
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } catch (_) {
    return const [];
  }
  final out = <DiscoveredCamera>[];
  for (final m in OnvifClient._all(doc, 'ProbeMatch')) {
    final xaddrs = (OnvifClient._text(m, 'XAddrs') ?? '').split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    final scopes = (OnvifClient._text(m, 'Scopes') ?? '').split(RegExp(r'\s+'));
    String? scope(String key) {
      final prefix = 'onvif://www.onvif.org/$key/';
      for (final s in scopes) {
        if (s.toLowerCase().startsWith(prefix)) return Uri.decodeComponent(s.substring(prefix.length));
      }
      return null;
    }

    String? host = sourceIp;
    for (final x in xaddrs) {
      host ??= Uri.tryParse(x)?.host;
    }
    if (host == null) continue;
    out.add(
      DiscoveredCamera(
        host: host,
        onvifUrl: xaddrs.firstWhere((x) => Uri.tryParse(x)?.host == host, orElse: () => xaddrs.isEmpty ? '' : xaddrs.first).isEmpty
            ? null
            : xaddrs.firstWhere((x) => Uri.tryParse(x)?.host == host, orElse: () => xaddrs.first),
        name: scope('name'),
        hardware: scope('hardware'),
      ),
    );
  }
  return out;
}

