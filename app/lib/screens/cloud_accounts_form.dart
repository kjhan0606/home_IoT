import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/credentials_store.dart';
import '../state/hub_state.dart';

/// Token entry for direct-cloud mode: SmartThings PAT and LG ThinQ PAT + country.
/// Tokens are written to secure storage (Keychain/Keystore) and never shown again
/// in clear text; an empty field leaves the stored token unchanged.
class CloudAccountsForm extends StatefulWidget {
  const CloudAccountsForm({super.key, this.onSaved});

  /// Called after a successful save (e.g. to close the screen).
  final VoidCallback? onSaved;

  @override
  State<CloudAccountsForm> createState() => _CloudAccountsFormState();
}

class _CloudAccountsFormState extends State<CloudAccountsForm> {
  final _st = TextEditingController();
  final _lg = TextEditingController();
  final _country = TextEditingController(text: 'KR');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final c = context.read<HubState>().creds;
    _country.text = c.lgCountry;
  }

  @override
  void dispose() {
    _st.dispose();
    _lg.dispose();
    _country.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final hub = context.read<HubState>();
    final messenger = ScaffoldMessenger.of(context);
    final country = _country.text.trim().toUpperCase();
    if (_lg.text.trim().isNotEmpty && !RegExp(r'^[A-Z]{2}$').hasMatch(country)) {
      messenger.showSnackBar(const SnackBar(content: Text('국가 코드는 영문 2글자(예: KR)로 입력하세요.')));
      return;
    }
    setState(() => _busy = true);
    try {
      final ok = await hub.saveTokens(
        smartThings: _st.text.trim().isEmpty ? null : _st.text,
        lgToken: _lg.text.trim().isEmpty ? null : _lg.text,
        lgCountry: country.isEmpty ? null : country,
      );
      _st.clear();
      _lg.clear();
      if (!mounted) return;
      if (!ok) {
        messenger.showSnackBar(const SnackBar(content: Text('토큰을 하나 이상 입력하세요.')));
      } else if (hub.error != null) {
        messenger.showSnackBar(
          SnackBar(content: Text('저장했지만 기기를 불러오지 못했습니다: ${hub.error}'), duration: const Duration(seconds: 6)),
        );
      } else {
        messenger.showSnackBar(SnackBar(content: Text('저장했습니다. 기기 ${hub.devices.length}개')));
      }
      if (ok) widget.onSaved?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String which) async {
    final hub = context.read<HubState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('$which 토큰 삭제'),
        content: const Text('이 기기에 저장된 토큰이 삭제됩니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true) return;
    if (which == 'SmartThings') {
      await hub.saveTokens(smartThings: '');
    } else {
      await hub.saveTokens(lgToken: '');
    }
  }

  static String _ago(Duration d) => d.inHours >= 1 ? '${d.inHours}시간 전' : '${d.inMinutes.clamp(0, 59)}분 전';

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<HubState>();
    final c = hub.creds;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final stAge = c.smartThingsAge(now);
    // A plain Column: the caller provides the scrolling (setup screen / accounts screen).
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (kIsWeb)
            Card(
              color: cs.errorContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('웹 브라우저에서는 CORS 정책 때문에 클라우드에 직접 연결이 막힐 수 있습니다. iOS/Android 앱에서 사용하세요.'),
              ),
            ),
          Text('Samsung SmartThings', style: t.titleMedium),
          const SizedBox(height: 4),
          Text(
            hub.smartThingsLikelyExpired
                ? '저장된 토큰이 24시간이 지나 만료되었을 가능성이 큽니다. 새 토큰을 입력하세요.'
                : c.hasSmartThings
                ? '저장됨${stAge == null ? '' : ' · ${_ago(stAge)} 입력'} (24시간 뒤 만료)'
                : '설정 안 됨',
            key: const Key('st-status'),
            style: t.bodySmall?.copyWith(color: hub.smartThingsLikelyExpired ? cs.error : null),
          ),
          const SizedBox(height: 8),
          Card(
            color: cs.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '주의: SmartThings 개인용 토큰(PAT)은 발급 후 24시간이 지나면 만료됩니다. '
                '만료되면 account.smartthings.com/tokens 에서 새 토큰을 발급(기기: 읽기/실행 권한)해 다시 입력해야 합니다. '
                '만료 없이 쓰려면 OAuth 로그인이 필요하며, 이는 작은 중계 서버가 있어야 해서 추후 지원 예정입니다.',
                style: TextStyle(color: cs.onTertiaryContainer),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('st-token'),
            controller: _st,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: c.hasSmartThings ? '새 SmartThings 토큰 (비워 두면 유지)' : 'SmartThings 개인용 토큰(PAT)',
              border: const OutlineInputBorder(),
            ),
          ),
          if (c.hasSmartThings)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('st-remove'),
                onPressed: _busy ? null : () => _remove('SmartThings'),
                icon: const Icon(Icons.delete_outline),
                label: const Text('저장된 토큰 삭제'),
              ),
            ),
          const Divider(height: 32),
          Text('LG ThinQ', style: t.titleMedium),
          const SizedBox(height: 4),
          Text(c.hasLg ? '저장됨 · 국가 ${c.lgCountry}' : '설정 안 됨', key: const Key('lg-status'), style: t.bodySmall),
          const SizedBox(height: 8),
          Text(
            'connect-pat.lgthinq.com 에서 개인용 토큰을 발급받으세요. LG ThinQ Connect는 세탁기·건조기·냉장고·로봇청소기를 지원하며 TV는 지원하지 않습니다.',
            style: t.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('lg-token'),
            controller: _lg,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: c.hasLg ? '새 LG ThinQ 토큰 (비워 두면 유지)' : 'LG ThinQ 개인용 토큰(PAT)',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('lg-country'),
            controller: _country,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            maxLength: 2,
            decoration: const InputDecoration(
              labelText: '국가 코드',
              helperText: '토큰 발급 시 선택한 국가 (한국: KR)',
              border: OutlineInputBorder(),
            ),
          ),
          if (c.hasLg)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('lg-remove'),
                onPressed: _busy ? null : () => _remove('LG ThinQ'),
                icon: const Icon(Icons.delete_outline),
                label: const Text('저장된 토큰 삭제'),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('save-tokens'),
            onPressed: _busy ? null : _save,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: const Text('저장하고 기기 불러오기'),
          ),
          const SizedBox(height: 12),
          Text(
            '토큰은 이 기기의 보안 저장소(iOS 키체인 / Android 키스토어)에만 저장되며, 각 회사의 서버와 직접 통신할 때만 사용됩니다. '
            '별도 서버를 거치지 않습니다.',
            style: t.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Convenience for screens: does [c] have anything worth showing?
bool hasAnyCredentials(CloudCredentials c) => c.hasAny;
