import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../backend/device_backend.dart';
import '../l10n/ko.dart';
import '../state/hub_state.dart';
import 'cloud_accounts_form.dart';
import 'connect_screen.dart';

/// First-run onboarding / "not connected" screen: pick how the app gets its
/// devices. Direct cloud (default, no server) or the self-hosted hub.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late BackendKind _mode = context.read<HubState>().settings.mode;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hub = context.watch<HubState>();
    return Scaffold(
      appBar: AppBar(title: const Text(Ko.appTitle)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('시작하기', style: t.headlineSmall),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text('기기 정보를 어디서 가져올지 선택하세요. 나중에 설정에서 바꿀 수 있습니다.', style: t.bodyMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<BackendKind>(
              key: const Key('mode-picker'),
              segments: const [
                ButtonSegment(value: BackendKind.directCloud, icon: Icon(Icons.cloud_outlined), label: Text('직접 연결')),
                ButtonSegment(value: BackendKind.hub, icon: Icon(Icons.hub_outlined), label: Text('홈 허브')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
          if (_mode == BackendKind.directCloud) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text('서버 없이 앱이 삼성 SmartThings와 LG ThinQ에 바로 연결합니다. 토큰만 있으면 됩니다.'),
            ),
            const CloudAccountsForm(),
          ] else
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '같은 Wi-Fi에서 실행 중인 HomeHub(직접 운영하는 서버)에 연결합니다. '
                    'TV 로컬 제어, Roborock 등 허브 전용 기능을 쓸 수 있습니다.',
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('open-hub-connect'),
                    onPressed: () async {
                      await hub.settings.setMode(BackendKind.hub);
                      if (!context.mounted) return;
                      await Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => ConnectScreen(initial: hub.settings.loadHub())));
                    },
                    icon: const Icon(Icons.wifi_find),
                    label: const Text('허브 찾기'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
