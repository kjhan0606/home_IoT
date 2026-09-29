import 'package:flutter/material.dart';

import 'cloud_accounts_form.dart';

/// Settings > 클라우드 계정: edit SmartThings / LG ThinQ tokens.
class CloudAccountsScreen extends StatelessWidget {
  const CloudAccountsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('클라우드 계정')),
    body: SingleChildScrollView(child: CloudAccountsForm(onSaved: () => Navigator.of(context).maybePop())),
  );
}
