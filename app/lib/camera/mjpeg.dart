import 'dart:async';
import 'dart:typed_data';

/// Splits a multipart/x-mixed-replace (or any concatenated) JPEG byte stream
/// into single frames by scanning for the JPEG start (FFD8) / end (FFD9)
/// markers, so it does not depend on the boundary string.
Stream<Uint8List> jpegFrames(Stream<List<int>> bytes, {int maxFrameBytes = 8 * 1024 * 1024}) async* {
  var buf = BytesBuilder(copy: false);
  var data = Uint8List(0);
  await for (final chunk in bytes) {
    buf.add(chunk);
    data = buf.takeBytes();
    var pos = 0;
    while (true) {
      final s = _find(data, 0xD8, pos);
      if (s < 0) {
        pos = data.length;
        break;
      }
      final e = _find(data, 0xD9, s + 2);
      if (e < 0) {
        pos = s; // keep the partial frame
        break;
      }
      yield Uint8List.sublistView(data, s, e + 2);
      pos = e + 2;
    }
    final rest = data.length - pos;
    buf = BytesBuilder(copy: false);
    if (rest > 0 && rest < maxFrameBytes) buf.add(Uint8List.sublistView(data, pos));
  }
}

/// Index of the marker (0xFF, [second]) at or after [from], or -1.
int _find(Uint8List d, int second, int from) {
  for (var i = from; i < d.length - 1; i++) {
    if (d[i] == 0xFF && d[i + 1] == second) return i;
  }
  return -1;
}
