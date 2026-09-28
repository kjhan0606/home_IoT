import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/hub_discovery.dart';
import '../l10n/ko.dart';
import '../models/hub_config.dart';
import '../state/hub_state.dart';

/// Finds the hub via Bonjour (`_homehub._tcp`) or takes a manual address.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.initial});
  final HubConfig? initial;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final _addr = TextEditingController(text: widget.initial?.label ?? _defaultAddress());
  late final _token = TextEditingController(text: widget.initial?.token ?? '');
  StreamSubscription<List<HubConfig>>? _sub;
  List<HubConfig> _found = const [];
  bool _searching = false;
  String? _discoveryError;
  late final HubDiscovery _disc = context.read<HubDiscovery>();
  Timer? _searchTimer;

  static String _defaultAddress() {
    // On the web build the hub usually serves/sits next to the page.
    if (kIsWeb && Uri.base.host.isNotEmpty) return '${Uri.base.host}:8099';
    return '';
  }

  @override
  void initState() {
    super.initState();
    _discover();
  }

  void _discover() {
    final disc = _disc;
    if (!disc.supported) return;
    _sub?.cancel();
    setState(() {
      _searching = true;
      _discoveryError = null;
    });
    _sub = disc.discover().listen(
      (list) => setState(() => _found = list),
      onError: (Object e) => setState(() {
        _discoveryError = '자동 검색 실패: $e';
        _searching = false;
      }),
    );
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _searching = false);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _searchTimer?.cancel();
    _disc.stop();
    _addr.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect(HubConfig c) async {
    final hub = context.read<HubState>();
    final ok = await hub.connect(c);
    if (!mounted) return;
    if (ok) {
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('연결 실패: ${hub.error}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<HubState>();
    final disc = _disc;
    final busy = hub.status == HubStatus.connecting;
    return Scaffold(
      appBar: AppBar(title: const Text('허브 연결')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('같은 Wi-Fi에 있는 HomeHub를 찾습니다.', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.wifi_find),
                  title: const Text('자동 검색'),
                  subtitle: Text(
                    !disc.supported
                        ? '이 플랫폼(웹)에서는 자동 검색을 지원하지 않습니다. 주소를 직접 입력하세요.'
                        : (_discoveryError ?? (_searching ? '검색 중…' : '찾은 허브 ${_found.length}개')),
                  ),
                  trailing: disc.supported
                      ? IconButton(tooltip: '다시 검색', onPressed: _discover, icon: const Icon(Icons.refresh))
                      : null,
                ),
                for (final h in _found)
                  ListTile(
                    leading: const Icon(Icons.hub_outlined),
                    title: Text(h.name ?? 'HomeHub'),
                    subtitle: Text(h.label),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: busy
                        ? null
                        : () => _connect(h.copyWith(token: _token.text.trim().isEmpty ? null : _token.text.trim())),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('직접 입력', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            key: const Key('hub-address'),
            controller: _addr,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '허브 주소 (IP:포트)',
              hintText: '192.168.0.10:8099',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('hub-token'),
            controller: _token,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '허브 비밀키 (선택)',
              helperText: '허브에 HOMEHUB_TOKEN을 설정한 경우에만 입력',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('connect'),
            onPressed: busy
                ? null
                : () {
                    final c = HubConfig.parse(_addr.text, token: _token.text);
                    if (c == null) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('주소 형식이 올바르지 않습니다.')));
                      return;
                    }
                    _connect(c);
                  },
            icon: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.link),
            label: const Text('연결'),
          ),
          if (hub.status == HubStatus.error && hub.error != null) ...[
            const SizedBox(height: 12),
            Text(hub.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 24),
          Text(
            '${Ko.appTitle}은 집 안의 HomeHub(로컬 게이트웨이)를 통해 기기를 제어합니다. '
            'iPhone에서는 처음 연결할 때 "로컬 네트워크" 접근 권한을 허용해야 합니다.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
