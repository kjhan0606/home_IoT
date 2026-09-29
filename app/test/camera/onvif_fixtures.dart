// Canned ONVIF SOAP answers (mirror of hub/tests/test_camera.py).
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const dev = 'http://192.168.0.50/onvif/device_service';
const media = 'http://192.168.0.50/onvif/media_service';
const ptzSvc = 'http://192.168.0.50/onvif/ptz_service';

String env(String body) =>
    '<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
    'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">'
    '<s:Body>$body</s:Body></s:Envelope>';

final timeXml = env(
  '<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:UTCDateTime>'
  '<tt:Time><tt:Hour>1</tt:Hour><tt:Minute>2</tt:Minute><tt:Second>3</tt:Second></tt:Time>'
  '<tt:Date><tt:Year>2026</tt:Year><tt:Month>9</tt:Month><tt:Day>29</tt:Day></tt:Date>'
  '</tt:UTCDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>',
);
final infoXml = env(
  '<tds:GetDeviceInformationResponse><tds:Manufacturer>ExampleCo</tds:Manufacturer><tds:Model>EC-100</tds:Model>'
  '<tds:FirmwareVersion>1.2</tds:FirmwareVersion><tds:SerialNumber>SN1</tds:SerialNumber><tds:HardwareId>HW</tds:HardwareId>'
  '</tds:GetDeviceInformationResponse>',
);
String capsXml({bool ptz = true}) => env(
  '<tds:GetCapabilitiesResponse><tds:Capabilities><tt:Media><tt:XAddr>$media</tt:XAddr></tt:Media>'
  '${ptz ? '<tt:PTZ><tt:XAddr>$ptzSvc</tt:XAddr></tt:PTZ>' : ''}</tds:Capabilities></tds:GetCapabilitiesResponse>',
);
String profilesXml({bool ptz = true}) {
  String prof(String tok, String name, int w, int h, String enc) =>
      '<trt:Profiles token="$tok" fixed="true"><tt:Name>$name</tt:Name><tt:VideoEncoderConfiguration><tt:Encoding>$enc</tt:Encoding>'
      '<tt:Resolution><tt:Width>$w</tt:Width><tt:Height>$h</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration>'
      '${ptz ? "<tt:PTZConfiguration token='p'><tt:Name>ptz</tt:Name></tt:PTZConfiguration>" : ''}</trt:Profiles>';
  return env('<trt:GetProfilesResponse>${prof('prof_main', 'mainStream', 1920, 1080, 'H264')}${prof('prof_sub', 'subStream', 640, 360, 'JPEG')}</trt:GetProfilesResponse>');
}

final streamUriXml = env('<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://192.168.0.50:554/live/main</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse>');
final snapUriXml = env('<trt:GetSnapshotUriResponse><trt:MediaUri><tt:Uri>http://192.168.0.50/snap.jpg</tt:Uri></trt:MediaUri></trt:GetSnapshotUriResponse>');
final presetsXml = env(
  '<tptz:GetPresetsResponse><tptz:Preset token="1"><tt:Name>Door</tt:Name></tptz:Preset>'
  '<tptz:Preset token="2"><tt:Name>Sofa</tt:Name></tptz:Preset></tptz:GetPresetsResponse>',
);
const faultAuth =
    '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault><s:Code><s:Value>s:Sender</s:Value>'
    '<s:Subcode><s:Value>ter:NotAuthorized</s:Value></s:Subcode></s:Code><s:Reason><s:Text>Sender not Authorized</s:Text></s:Reason>'
    '</s:Fault></s:Body></s:Envelope>';
const faultNoSnap =
    '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault><s:Code><s:Value>s:Sender</s:Value>'
    '<s:Subcode><s:Value>ter:ActionNotSupported</s:Value></s:Subcode></s:Code><s:Reason><s:Text>Optional Action Not Implemented</s:Text></s:Reason>'
    '</s:Fault></s:Body></s:Envelope>';

/// 1x1-ish fake JPEG (SOI ... EOI). Not decodable, which is fine for logic tests.
final fakeJpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x46, 0x41, 0x4B, 0x45, 0xFF, 0xD9];

class SoapCall {
  SoapCall(this.url, this.body);
  final String url, body;
}

/// A fake camera on the LAN: SOAP by operation name, plus a JPEG snapshot URL.
class FakeCamera {
  FakeCamera({this.ptz = true, this.snapshot = true, this.authOk = true});
  bool ptz, snapshot, authOk;
  final List<SoapCall> soap = [];
  final List<String> gets = [];
  String? snapshotAuthHeader;
  bool snapshotNeedsBasic = false;

  late final MockClient client = MockClient((req) async {
    if (req.method == 'GET') {
      gets.add(req.url.toString());
      if (req.url.path == '/snap.jpg') {
        if (snapshotNeedsBasic && !(req.headers['Authorization'] ?? '').startsWith('Basic ')) {
          return http.Response('', 401, headers: {'www-authenticate': 'Basic realm="cam"'});
        }
        snapshotAuthHeader = req.headers['Authorization'];
        return http.Response.bytes(fakeJpeg, 200, headers: {'content-type': 'image/jpeg'});
      }
      if (req.url.path == '/video') {
        return http.Response.bytes([...utf8.encode('--f\r\n'), ...fakeJpeg], 200, headers: {'content-type': 'multipart/x-mixed-replace;boundary=f'});
      }
      if (req.url.path == '/page') return http.Response('hi', 200, headers: {'content-type': 'text/html'});
      return http.Response('', 404);
    }
    final body = req.body;
    soap.add(SoapCall(req.url.toString(), body));
    if (!authOk && !body.contains('GetSystemDateAndTime')) {
      return http.Response(faultAuth, 400, headers: {'content-type': 'application/soap+xml'});
    }
    String? out;
    for (final e in {
      'GetSystemDateAndTime': timeXml,
      'GetDeviceInformation': infoXml,
      'GetCapabilities': capsXml(ptz: ptz),
      'GetProfiles': profilesXml(ptz: ptz),
      'GetStreamUri': streamUriXml,
      'GetPresets': presetsXml,
      'ContinuousMove': env('<tptz:ContinuousMoveResponse/>'),
      'GotoPreset': env('<tptz:GotoPresetResponse/>'),
      '<tptz:Stop>': env('<tptz:StopResponse/>'),
    }.entries) {
      if (body.contains(e.key.startsWith('<') ? e.key : '<tds:${e.key}') ||
          body.contains('<trt:${e.key}') ||
          body.contains('<tptz:${e.key}')) {
        out = e.value;
        break;
      }
    }
    if (body.contains('GetSnapshotUri')) {
      return snapshot
          ? http.Response(snapUriXml, 200, headers: {'content-type': 'application/soap+xml'})
          : http.Response(faultNoSnap, 400, headers: {'content-type': 'application/soap+xml'});
    }
    return out == null ? http.Response('unknown', 400) : http.Response(out, 200, headers: {'content-type': 'application/soap+xml'});
  });
}
