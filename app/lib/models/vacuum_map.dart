import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

/// Row-major 2x3 affine transform `[[a,b,c],[d,e,f]]`:
/// `u = a*x + b*y + c`, `v = d*x + e*y + f`.
class Affine {
  const Affine(this.m);
  final List<List<double>> m;

  static Affine? fromJson(Object? j) {
    if (j is! List || j.length != 2) return null;
    final rows = j.map((r) => (r as List).map((e) => (e as num).toDouble()).toList()).toList();
    if (rows.any((r) => r.length != 3)) return null;
    return Affine(rows);
  }

  Offset apply(Offset p) =>
      Offset(m[0][0] * p.dx + m[0][1] * p.dy + m[0][2], m[1][0] * p.dx + m[1][1] * p.dy + m[1][2]);
}

class MapRoom {
  const MapRoom({required this.id, required this.name, required this.imageBox, this.mapBox});
  final String id;
  final String name;
  final Rect imageBox; // image pixels
  final Rect? mapBox; // map coordinates

  static Rect? _box(Object? j) {
    if (j is! Map) return null;
    double v(String k) => (j[k] as num).toDouble();
    return Rect.fromLTRB(v('x0'), v('y0'), v('x1'), v('y1'));
  }

  factory MapRoom.fromJson(Map<String, dynamic> j) {
    final bbox = (j['bbox'] as Map?) ?? const {};
    return MapRoom(
      id: j['id'].toString(),
      name: (j['name'] as String?) ?? j['id'].toString(),
      imageBox: _box(bbox['image']) ?? Rect.zero,
      mapBox: _box(bbox['map']),
    );
  }
}

/// `GET /devices/{id}/map` payload (brand-neutral; see hub/homehub/vacuum_map.py).
class VacuumMap {
  const VacuumMap({
    required this.width,
    required this.height,
    required this.mapToImage,
    required this.imageToMap,
    this.rooms = const [],
    this.robot,
    this.dock,
    this.png,
    this.mapName,
    this.isExample = false,
  });

  final double width;
  final double height;
  final Affine mapToImage;
  final Affine imageToMap;
  final List<MapRoom> rooms;
  final Offset? robot; // image pixels
  final Offset? dock; // image pixels
  final Uint8List? png;
  final String? mapName;
  final bool isExample;

  static Offset? _pt(Object? j) {
    if (j is! Map || j['image'] is! Map) return null;
    final p = j['image'] as Map;
    return Offset((p['x'] as num).toDouble(), (p['y'] as num).toDouble());
  }

  factory VacuumMap.fromJson(Map<String, dynamic> j) {
    final image = Map<String, dynamic>.from((j['image'] as Map?) ?? const {});
    final t = (j['transform'] as Map?) ?? const {};
    final m2i = Affine.fromJson(t['mapToImage']);
    final i2m = Affine.fromJson(t['imageToMap']);
    if (m2i == null || i2m == null) {
      throw const FormatException('map metadata has no pixel<->map transform');
    }
    final b64 = image['pngBase64'] as String?;
    return VacuumMap(
      width: ((image['width'] as num?) ?? 0).toDouble(),
      height: ((image['height'] as num?) ?? 0).toDouble(),
      mapToImage: m2i,
      imageToMap: i2m,
      rooms: ((j['rooms'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => MapRoom.fromJson(Map<String, dynamic>.from(r)))
          .toList(),
      robot: _pt(j['robot']),
      dock: _pt(j['dock']),
      png: b64 == null ? null : base64Decode(b64),
      mapName: j['mapName'] as String?,
      isExample: j['demo'] == true,
    );
  }

  /// Image-pixel point -> map coordinates (what goTo / zone commands take).
  Offset toMap(Offset imagePx) => imageToMap.apply(imagePx);

  /// Smallest room whose image bbox contains the point (bboxes may overlap).
  MapRoom? roomAt(Offset imagePx) {
    MapRoom? best;
    for (final r in rooms) {
      if (!r.imageBox.contains(imagePx)) continue;
      if (best == null || r.imageBox.width * r.imageBox.height < best.imageBox.width * best.imageBox.height) {
        best = r;
      }
    }
    return best;
  }

  /// Image-pixel rectangle -> `[x1, y1, x2, y2]` in map coordinates (min/max
  /// normalised, rounded), the canonical `zoneCleaning.cleanZones` format.
  List<int> zoneToMap(Rect imageRect) {
    final a = toMap(imageRect.topLeft);
    final b = toMap(imageRect.bottomRight);
    return [
      (a.dx < b.dx ? a.dx : b.dx).round(),
      (a.dy < b.dy ? a.dy : b.dy).round(),
      (a.dx > b.dx ? a.dx : b.dx).round(),
      (a.dy > b.dy ? a.dy : b.dy).round(),
    ];
  }
}
