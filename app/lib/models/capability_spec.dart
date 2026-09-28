/// Canonical capability schema from `GET /capabilities` (actions, state, uiHint).
class CapabilitySpec {
  const CapabilitySpec({required this.key, required this.uiHint, this.actions = const {}, this.state = const {}});

  final String key;
  final String uiHint;
  final Map<String, Map<String, dynamic>> actions;
  final Map<String, String> state;

  factory CapabilitySpec.fromJson(String key, Map<String, dynamic> j) => CapabilitySpec(
    key: key,
    uiHint: (j['uiHint'] as String?) ?? 'generic',
    actions: ((j['actions'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(k.toString(), Map<String, dynamic>.from((v as Map?) ?? const {})),
    ),
    state: ((j['state'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), v.toString())),
  );

  static Map<String, CapabilitySpec> parseCatalog(Map<String, dynamic> body) {
    final canon = (body['canonical'] as Map?) ?? const {};
    return canon.map(
      (k, v) => MapEntry(k.toString(), CapabilitySpec.fromJson(k.toString(), Map<String, dynamic>.from(v as Map))),
    );
  }
}
