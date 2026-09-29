/// Brand-neutral device model mirroring the hub's `Device.to_dict()`.
///
/// The app never looks at `adapter`/`vendor` to decide behaviour; everything
/// is driven by [capabilities] (canonical keys, supported actions, state).
class CapabilityInstance {
  const CapabilityInstance({required this.key, this.actions = const [], this.state = const {}});

  final String key;
  final List<String> actions;
  final Map<String, dynamic> state;

  bool supports(String action) => actions.contains(action);

  T? get<T>(String field) {
    final v = state[field];
    return v is T ? v : null;
  }

  num? number(String field) => state[field] is num ? state[field] as num : null;

  List<String> strings(String field) => (state[field] as List?)?.map((e) => e.toString()).toList() ?? const [];

  List<Map<String, dynamic>> objects(String field) =>
      (state[field] as List?)?.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() ?? const [];

  factory CapabilityInstance.fromJson(String fallbackKey, Map<String, dynamic> j) => CapabilityInstance(
    key: (j['key'] as String?) ?? fallbackKey,
    actions: (j['actions'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    state: Map<String, dynamic>.from((j['state'] as Map?) ?? const {}),
  );
}

class Device {
  const Device({
    required this.id,
    required this.name,
    this.kind = 'unknown',
    this.adapter = 'unknown',
    this.ip,
    this.reachable = false,
    this.controllable = false,
    this.capabilities = const {},
    this.meta = const {},
  });

  final String id;
  final String name;
  final String kind;
  final String adapter; // informational only; never used for UI decisions
  final String? ip;
  final bool reachable;
  final bool controllable;
  final Map<String, CapabilityInstance> capabilities;
  final Map<String, dynamic> meta;

  Device copyWith({bool? reachable, Map<String, CapabilityInstance>? capabilities, Map<String, dynamic>? meta}) =>
      Device(
        id: id,
        name: name,
        kind: kind,
        adapter: adapter,
        ip: ip,
        reachable: reachable ?? this.reachable,
        controllable: controllable,
        capabilities: capabilities ?? this.capabilities,
        meta: meta ?? this.meta,
      );

  CapabilityInstance? cap(String key) => capabilities[key];
  bool has(String key) => capabilities.containsKey(key);

  /// Optional generic room label (`meta.room`) if an adapter provides one.
  String? get room => meta['room'] is String && (meta['room'] as String).isNotEmpty ? meta['room'] as String : null;

  /// Sample devices from the hub's dev-only demo mode.
  bool get isExample => meta['demo'] == true;

  bool? get powerOn {
    final s = capabilities['power']?.state['switch'];
    return s == null ? null : s == 'on';
  }

  factory Device.fromJson(Map<String, dynamic> j) {
    final caps = <String, CapabilityInstance>{};
    ((j['capabilities'] as Map?) ?? const {}).forEach((k, v) {
      if (v is Map) caps[k.toString()] = CapabilityInstance.fromJson(k.toString(), Map<String, dynamic>.from(v));
    });
    return Device(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? (j['id'] as String),
      kind: (j['kind'] as String?) ?? 'unknown',
      adapter: (j['adapter'] as String?) ?? 'unknown',
      ip: j['ip'] as String?,
      reachable: j['reachable'] == true,
      controllable: j['controllable'] == true,
      capabilities: caps,
      meta: Map<String, dynamic>.from((j['meta'] as Map?) ?? const {}),
    );
  }
}
