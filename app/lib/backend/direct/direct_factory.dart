import 'package:http/http.dart' as http;

import '../../state/credentials_store.dart';
import '../device_backend.dart';
import 'direct_cloud_backend.dart';
import 'lg_thinq_client.dart';
import 'smartthings_client.dart';

/// Builds the direct-cloud backend for whichever tokens the user entered.
typedef DirectBackendFactory = Future<DeviceBackend> Function(CredentialsStore store);

Future<DeviceBackend> defaultDirectBackendFactory(
  CredentialsStore store, {
  http.Client? client,
  Duration? pollInterval = const Duration(seconds: 60),
  Duration settleDelay = const Duration(milliseconds: 800),
}) async {
  final creds = await store.load();
  return DirectCloudBackend(
    pollInterval: pollInterval,
    settleDelay: settleDelay,
    providers: [
      if (creds.hasSmartThings) SmartThingsClient(token: store.smartThingsToken, client: client),
      if (creds.hasLg)
        LgThinqClient(
          token: store.lgToken,
          country: creds.lgCountry,
          clientId: await store.lgClientId(),
          client: client,
        ),
    ],
  );
}
