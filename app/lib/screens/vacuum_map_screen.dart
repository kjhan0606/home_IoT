import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/hub_api.dart';
import '../l10n/ko.dart';
import '../models/vacuum_map.dart';
import '../state/hub_state.dart';
import '../widgets/capabilities/vacuum.dart';
import '../widgets/command.dart';

enum MapMode { rooms, zones }

/// Interactive vacuum map (brand-neutral `GET /devices/{id}/map`):
/// tap rooms to select them, draw up to `maxZones` rectangles, long-press to
/// send the robot to a point. Taps are converted image-pixel -> map
/// coordinates with the hub-provided `imageToMap` transform.
class VacuumMapScreen extends StatefulWidget {
  const VacuumMapScreen({super.key, required this.deviceId});
  final String deviceId;

  @override
  State<VacuumMapScreen> createState() => _VacuumMapScreenState();
}

class _VacuumMapScreenState extends State<VacuumMapScreen> {
  VacuumMap? _map;
  String? _error;
  bool _loading = true;
  MapMode _mode = MapMode.rooms;
  final Set<String> _rooms = {};
  final List<Rect> _zones = [];
  Offset? _dragStart;
  Rect? _drag;
  int _repeat = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<HubState>().api;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final m = await api!.vacuumMap(widget.deviceId);
      if (mounted) setState(() => _map = m);
    } on HubApiException catch (e) {
      if (mounted) setState(() => _error = e.statusCode == 0 ? e.message : '지도를 불러오지 못했습니다: ${e.message}');
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = '지도 데이터 형식 오류: ${e.message}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _goTo(Offset imagePx) async {
    final map = _map!;
    final p = map.toMap(imagePx);
    final room = map.roomAt(imagePx);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('이 위치로 이동할까요?'),
        content: Text('${room != null ? '${room.name} · ' : ''}지도 좌표 (${p.dx.round()}, ${p.dy.round()})'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('이동')),
        ],
      ),
    );
    if (ok == true && mounted) {
      final sent = await sendCommand(
        context,
        widget.deviceId,
        'goTo',
        'goTo',
        params: {'x': p.dx.round(), 'y': p.dy.round()},
        successMessage: '지정 위치로 이동합니다.',
      );
      if (sent && mounted) _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<HubState>().device(widget.deviceId);
    final roomCap = device?.cap('roomCleaning');
    final zoneCap = device?.cap('zoneCleaning');
    final canGoTo = device?.cap('goTo')?.supports('goTo') ?? false;
    final modes = [
      if (roomCap?.supports('cleanRooms') ?? false) MapMode.rooms,
      if (zoneCap?.supports('cleanZones') ?? false) MapMode.zones,
    ];
    if (modes.isNotEmpty && !modes.contains(_mode)) _mode = modes.first;
    final maxZones = (zoneCap?.number('maxZones') ?? 5).toInt();
    final maxRepeat = ((_mode == MapMode.rooms ? roomCap : zoneCap)?.number('maxRepeat') ?? 1).toInt().clamp(1, 9);
    final map = _map;

    return Scaffold(
      appBar: AppBar(
        title: Text(device == null ? '지도' : '${device.name} 지도'),
        actions: [
          if (map?.isExample ?? false)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Chip(label: Text(Ko.example), visualDensity: VisualDensity.compact),
            ),
          IconButton(tooltip: '새로고침', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          if (modes.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SegmentedButton<MapMode>(
                segments: const [
                  ButtonSegment(value: MapMode.rooms, icon: Icon(Icons.meeting_room_outlined), label: Text('방 선택')),
                  ButtonSegment(value: MapMode.zones, icon: Icon(Icons.crop_square), label: Text('구역 그리기')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              [
                if (_mode == MapMode.rooms && modes.contains(MapMode.rooms)) '방을 눌러 선택하세요.',
                if (_mode == MapMode.zones) '드래그해서 구역을 그리세요 (최대 $maxZones개).',
                if (canGoTo) '길게 누르면 그 위치로 이동합니다.',
              ].join(' '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: _buildMap(map, canGoTo, maxZones)),
          if (map != null && modes.isNotEmpty) _buildActions(maxRepeat, maxZones),
        ],
      ),
    );
  }

  Widget _buildMap(VacuumMap? map, bool canGoTo, int maxZones) {
    if (_loading && map == null) return const Center(child: CircularProgressIndicator());
    if (_error != null && map == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }
    if (map == null || map.png == null || map.width <= 0 || map.height <= 0) {
      return const Center(child: Text('지도 이미지가 없습니다.'));
    }
    return LayoutBuilder(
      builder: (context, box) {
        final scale = [box.maxWidth / map.width, box.maxHeight / map.height].reduce((a, b) => a < b ? a : b);
        Offset toImage(Offset local) => local / scale;
        return Center(
          child: SizedBox(
            width: map.width * scale,
            height: map.height * scale,
            child: Semantics(
              label: '청소 지도',
              container: true,
              child: GestureDetector(
                key: const Key('map-canvas'),
                dragStartBehavior: DragStartBehavior.down, // zone starts where the finger went down
                // Position-based gestures; screen-reader users get the room chips on the detail screen.
                excludeFromSemantics: true,
                onTapUp: _mode == MapMode.rooms
                    ? (d) {
                        final r = map.roomAt(toImage(d.localPosition));
                        if (r != null) setState(() => _rooms.contains(r.id) ? _rooms.remove(r.id) : _rooms.add(r.id));
                      }
                    : null,
                onPanStart: _mode == MapMode.zones && _zones.length < maxZones
                    ? (d) => setState(() {
                        _dragStart = toImage(d.localPosition);
                        _drag = Rect.fromPoints(_dragStart!, _dragStart!);
                      })
                    : null,
                onPanUpdate: _mode == MapMode.zones
                    ? (d) {
                        if (_dragStart == null) return;
                        final p = toImage(d.localPosition);
                        setState(
                          () => _drag = Rect.fromPoints(
                            _dragStart!,
                            Offset(p.dx.clamp(0, map.width), p.dy.clamp(0, map.height)),
                          ),
                        );
                      }
                    : null,
                onPanEnd: _mode == MapMode.zones
                    ? (_) => setState(() {
                        final r = _drag;
                        if (r != null && r.width >= 4 && r.height >= 4) _zones.add(r);
                        _drag = null;
                        _dragStart = null;
                      })
                    : null,
                onLongPressStart: canGoTo ? (d) => _goTo(toImage(d.localPosition)) : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(map.png!, fit: BoxFit.fill, gaplessPlayback: true, filterQuality: FilterQuality.none),
                    CustomPaint(
                      painter: MapOverlayPainter(
                        map: map,
                        scale: scale,
                        selectedRooms: _rooms,
                        zones: [..._zones, ?_drag],
                        colors: Theme.of(context).colorScheme,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildActions(int maxRepeat, int maxZones) {
    final rooms = _mode == MapMode.rooms;
    final count = rooms ? _rooms.length : _zones.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (rooms && _rooms.isNotEmpty)
              Text('선택: ${_map!.rooms.where((r) => _rooms.contains(r.id)).map((r) => r.name).join(', ')}'),
            RepeatSelector(max: maxRepeat, value: _repeat, onChanged: (v) => setState(() => _repeat = v)),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton(
                  onPressed: count == 0 ? null : () => setState(() => rooms ? _rooms.clear() : _zones.clear()),
                  child: const Text('지우기'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('clean-selection'),
                    onPressed: count == 0 ? null : () => rooms ? _cleanRooms() : _cleanZones(),
                    icon: const Icon(Icons.cleaning_services),
                    label: Text(
                      count == 0 ? (rooms ? '방을 선택하세요' : '구역을 그리세요') : (rooms ? '$count개 방 청소' : '$count개 구역 청소'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _cleanRooms() => sendCommand(
    context,
    widget.deviceId,
    'roomCleaning',
    'cleanRooms',
    params: {'roomIds': _rooms.toList(), 'repeat': _repeat},
    successMessage: '선택한 방 청소를 시작합니다.',
  );

  Future<void> _cleanZones() => sendCommand(
    context,
    widget.deviceId,
    'zoneCleaning',
    'cleanZones',
    params: {'zones': _zones.map(_map!.zoneToMap).toList(), 'repeat': _repeat},
    successMessage: '구역 청소를 시작합니다.',
  );
}

class MapOverlayPainter extends CustomPainter {
  MapOverlayPainter({
    required this.map,
    required this.scale,
    required this.selectedRooms,
    required this.zones,
    required this.colors,
  });

  final VacuumMap map;
  final double scale;
  final Set<String> selectedRooms;
  final List<Rect> zones;
  final ColorScheme colors;

  Rect _s(Rect r) => Rect.fromLTRB(r.left * scale, r.top * scale, r.right * scale, r.bottom * scale);

  void _label(Canvas c, String text, Offset center, {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: bold ? FontWeight.bold : FontWeight.w500,
          shadows: const [Shadow(blurRadius: 3, color: Colors.black)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final r in map.rooms) {
      final box = _s(r.imageBox);
      final sel = selectedRooms.contains(r.id);
      if (sel) {
        canvas.drawRect(box, Paint()..color = colors.primary.withValues(alpha: 0.45));
        canvas.drawRect(
          box,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = colors.primary,
        );
      }
    }
    for (var i = 0; i < zones.length; i++) {
      final z = _s(zones[i]);
      canvas.drawRect(z, Paint()..color = colors.tertiary.withValues(alpha: 0.30));
      canvas.drawRect(
        z,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colors.tertiary,
      );
      _label(canvas, '${i + 1}', z.center, bold: true);
    }
    if (map.dock != null) {
      final d = map.dock! * scale;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: d, width: 16, height: 16), const Radius.circular(3)),
        Paint()..color = Colors.green.shade600,
      );
      _label(canvas, '⌂', d);
    }
    if (map.robot != null) {
      final r = map.robot! * scale;
      canvas.drawCircle(r, 10, Paint()..color = Colors.white);
      canvas.drawCircle(r, 7, Paint()..color = colors.primary);
    }
    // Labels last so markers never hide room names.
    for (final r in map.rooms) {
      final sel = selectedRooms.contains(r.id);
      _label(canvas, sel ? '✓ ${r.name}' : r.name, _s(r.imageBox).center + const Offset(0, 16), bold: sel);
    }
  }

  @override
  bool shouldRepaint(covariant MapOverlayPainter old) => true; // cheap; selection sets are mutated in place
}
