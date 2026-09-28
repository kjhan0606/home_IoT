import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/hub_api.dart';
import '../state/hub_state.dart';
import 'connect_screen.dart';

/// Hub address, integration status, Roborock account link.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _integrations;
  Map<String, dynamic> _cloudErrors = const {};
  Map<String, dynamic>? _roborock;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<HubState>().api;
    if (api == null) return;
    try {
      final i = await api.integrations();
      Map<String, dynamic>? rr;
      final ints = Map<String, dynamic>.from((i['integrations'] as Map?) ?? const {});
      if (ints.containsKey('roborock')) {
        try {
          rr = await api.roborockStatus();
        } on HubApiException catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _integrations = ints;
        _cloudErrors = Map<String, dynamic>.from((i['cloudErrors'] as Map?) ?? const {});
        _roborock = rr;
        _error = null;
      });
    } on HubApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  static const _help = {
    'smartthings': '허브에서 SMARTTHINGS_TOKEN 환경변수로 설정합니다 (account.smartthings.com/tokens 에서 발급).',
    'lg_thinq': '허브에서 LG_THINQ_TOKEN(과 LG_THINQ_COUNTRY) 환경변수로 설정합니다 (connect-pat.lgthinq.com 에서 발급).',
    'samsung_local': '같은 네트워크의 삼성 TV를 자동으로 찾습니다. TV에 표시되는 허용 요청을 수락하세요.',
    'demo': '개발용 예시 기기입니다 (HOMEHUB_FAKE_DEVICES=1).',
  };

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<HubState>();
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _section(context, '허브'),
            ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: Text(hub.hubName ?? 'HomeHub'),
              subtitle: Text(
                '${hub.config?.label ?? '-'}${hub.config?.token != null ? ' · 비밀키 사용' : ''} · ${hub.liveConnected ? '실시간 연결됨' : '실시간 연결 끊김'}',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('허브 변경'),
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConnectScreen(initial: hub.config))),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('연결 해제'),
              onTap: () async {
                await hub.disconnect(forget: true);
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
            const Divider(),
            _section(context, '연동 상태'),
            if (_error != null)
              ListTile(
                title: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (_integrations == null && _error == null)
              const Center(
                child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
              ),
            for (final e in (_integrations ?? const {}).entries)
              if (e.key != 'roborock')
                ListTile(
                  key: Key('integration-${e.key}'),
                  leading: Icon(
                    (e.value as Map)['enabled'] == true ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: (e.value as Map)['enabled'] == true ? Colors.green : null,
                  ),
                  title: Text('${(e.value as Map)['name'] ?? e.key}'),
                  subtitle: Text(
                    [
                      (e.value as Map)['enabled'] == true ? '사용 중' : '설정 안 됨',
                      if (_cloudErrors[e.key] != null) '오류: ${_cloudErrors[e.key]}',
                      if (_help[e.key] != null) _help[e.key]!,
                    ].join('\n'),
                  ),
                  isThreeLine: true,
                ),
            if (_integrations?.containsKey('roborock') ?? false) ...[
              const Divider(),
              _section(context, 'Roborock 계정'),
              RoborockLinkPanel(status: _roborock, onChanged: _load, cloudError: _cloudErrors['roborock']?.toString()),
            ],
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('토큰과 계정 정보는 허브에만 저장되며 앱에는 저장되지 않습니다.', style: t.bodySmall),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// Email -> request code -> log in with code (or password) ; unlink.
class RoborockLinkPanel extends StatefulWidget {
  const RoborockLinkPanel({super.key, required this.status, required this.onChanged, this.cloudError});
  final Map<String, dynamic>? status;
  final Future<void> Function() onChanged;
  final String? cloudError;

  @override
  State<RoborockLinkPanel> createState() => _RoborockLinkPanelState();
}

class _RoborockLinkPanelState extends State<RoborockLinkPanel> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _codeSent = false;
  bool _usePassword = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(HubApi api) fn) async {
    final api = context.read<HubState>().api;
    final messenger = ScaffoldMessenger.of(context);
    if (api == null) return;
    setState(() => _busy = true);
    try {
      await fn(api);
    } on HubApiException catch (e) {
      final msg = e.statusCode == 429 ? '요청이 너무 많습니다. 잠시 후 다시 시도하세요.' : e.message;
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.status;
    if (s == null) return const ListTile(title: Text('상태를 불러오는 중…'));
    final linked = s['linked'] == true;
    if (linked) {
      final devices = (s['devices'] as List?) ?? const [];
      return Column(
        children: [
          ListTile(
            leading: const Icon(Icons.check_circle, color: Colors.green),
            title: Text('연결됨: ${s['account'] ?? ''}'),
            subtitle: Text(
              ['기기 ${devices.length}대', if (widget.cloudError != null) '오류: ${widget.cloudError}'].join(' · '),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              key: const Key('roborock-unlink'),
              onPressed: _busy
                  ? null
                  : () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Roborock 연결 해제'),
                          content: const Text('허브에 저장된 Roborock 인증 정보와 기기 키가 삭제됩니다.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('해제')),
                          ],
                        ),
                      );
                      if (ok != true || !context.mounted) return;
                      final hub = context.read<HubState>();
                      await _run((api) async {
                        await api.roborockUnlink();
                        await widget.onChanged();
                        await hub.reload();
                      });
                    },
              icon: const Icon(Icons.link_off),
              label: const Text('연결 해제'),
            ),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Roborock 앱 계정으로 한 번 로그인하면, 이후에는 가능한 경우 같은 네트워크에서 직접 제어합니다. '
            '(비공식 API — 펌웨어/서버 변경 시 동작하지 않을 수 있음)',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('roborock-email'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Roborock 계정 이메일', border: OutlineInputBorder()),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('비밀번호로 로그인'),
            value: _usePassword,
            onChanged: (v) => setState(() => _usePassword = v),
          ),
          if (_usePassword) ...[
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: '비밀번호 (허브에 저장되지 않음)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run((api) async {
                      await api.roborockLogin(_email.text.trim(), password: _password.text);
                      _password.clear();
                      await _afterLogin();
                    }),
              child: const Text('로그인'),
            ),
          ] else ...[
            FilledButton.tonal(
              key: const Key('roborock-request-code'),
              onPressed: _busy
                  ? null
                  : () {
                      final messenger = ScaffoldMessenger.of(context);
                      _run((api) async {
                        await api.roborockRequestCode(_email.text.trim());
                        if (!mounted) return;
                        setState(() => _codeSent = true);
                        messenger.showSnackBar(const SnackBar(content: Text('인증 코드를 이메일로 보냈습니다.')));
                      });
                    },
              child: Text(_codeSent ? '코드 다시 받기' : '인증 코드 받기'),
            ),
            if (_codeSent) ...[
              const SizedBox(height: 8),
              TextField(
                key: const Key('roborock-code'),
                controller: _code,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '이메일로 받은 인증 코드', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('roborock-login'),
                onPressed: _busy
                    ? null
                    : () => _run((api) async {
                        await api.roborockLogin(_email.text.trim(), code: _code.text.trim());
                        await _afterLogin();
                      }),
                child: const Text('로그인'),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _afterLogin() async {
    if (!mounted) return;
    final hub = context.read<HubState>();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Roborock 계정이 연결되었습니다. 기기를 검색합니다…')));
    await widget.onChanged();
    try {
      await hub.scan();
    } catch (_) {}
  }
}
