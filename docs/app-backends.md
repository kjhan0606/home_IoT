# App backends: direct cloud, hub, and a future relay

The Flutter app gets its devices from a **backend**. The UI is capability-driven and
never knows which backend is active or which brand a device is.

| Mode | Needs a server? | What it is | Status |
|---|---|---|---|
| **Direct cloud** (default for new installs) | No | The app calls SmartThings and LG ThinQ Connect itself, with your personal tokens | Built, unit-tested with mocked HTTP; **not tried with real tokens/devices** |
| **Hub** | Yes (your own, same Wi-Fi) | The Python HomeHub over HTTP + WebSocket. Adds Samsung TV local control, Roborock, robot-vacuum maps | Unchanged, still works |
| **Relay** (future, optional, paid) | Hosted by the project | Push notifications, Roborock, SmartThings OAuth relay | Not built; the extension point exists |

An install that already remembers a hub keeps using hub mode. A new install starts in direct
mode and shows an onboarding screen. Switching is in Settings > 연결 방식.

## How it is wired (`app/lib/`)

```
backend/device_backend.dart          DeviceBackend interface, BackendKind {directCloud, hub, relay},
                                     BackendException (HTTP-style status codes), BackendEvent
backend/direct/cloud_provider.dart   CloudProvider = one vendor cloud (list / refresh / execute)
backend/direct/smartthings_client.dart   port of hub/homehub/adapters/smartthings.py
backend/direct/lg_thinq_client.dart      port of hub/homehub/adapters/lg_thinq.py
backend/direct/direct_cloud_backend.dart DeviceBackend that merges CloudProviders
api/hub_api.dart                     HttpHubApi implements DeviceBackend (hub mode) + hub-only extras
models/canonical_catalog.dart        GENERATED copy of hub/homehub/capabilities.py (no hub to serve /capabilities)
state/credentials_store.dart         SmartThings PAT, LG PAT + country -> Keychain / Keystore
state/hub_state.dart                 session over the active DeviceBackend (event stream or polling)
screens/setup_screen.dart            onboarding: pick mode, enter tokens
screens/cloud_accounts_*.dart        token entry / change / delete
```

`DeviceBackend` covers: `capabilities()`, `devices()`, `device()`, `refresh()`, `sync()`, `scan()`,
`command()`, `vacuumMap()`, `events()`, plus `warnings`, `pollInterval` and `hasEventStream` so one
UI works for a push backend (hub WebSocket) and a polling backend (direct cloud, 60 s, paused
in the background).

### What the direct clients port from the hub

Same brand-neutral output, so the existing widgets render it unchanged:

- **SmartThings:** paginated `GET /devices`, per-device `/status`, `POST /commands`. Maps switch,
  audioVolume/audioMute, tvChannel, (samsungvd.)mediaInputSource, mediaPlayback, switchLevel, lock,
  washer/dryer (with `remoteControlStatus`), refrigerator (cooler/freezer components, rapid
  cooling/freezing) and robot cleaner to `power`, `volume`, `channel`, `mediaInput`, `mediaPlayback`,
  `brightness`, `lock`, `washer`, `dryer`, `refrigeration`, `vacuum`.
- **LG ThinQ Connect:** region from country (`kic`/`aic`/`eic`), the SDK's headers, `/devices`,
  `/profile` + `/state`, `/control`. Washer, dryer (incl. tower locations), refrigerator and robot
  cleaner. Only actions the device profile marks writable are offered. ThinQ Connect has no TV.
- **Remote-start refusal:** washer/dryer `start` re-reads the live remote-control flag and refuses
  (403, Korean message) when it is off, without sending anything. LG error code 2301 is mapped to the
  same refusal.
- One provider failing (e.g. expired SmartThings PAT) does not hide the other's devices; it shows as a
  banner with a shortcut to the token screen.

### IP cameras (both modes)

`DirectCameraProvider` (id `camera`) is always part of direct mode, so cameras work without any cloud account. In hub mode
the same UI goes through the hub's `/cameras*` endpoints. Both implement `CameraBackend` (`backend/device_backend` consumers
only ask `backend is CameraBackend`). See [cameras.md](cameras.md).

### Not available in direct mode

Samsung TV local control (WoL + WebSocket), Roborock, the vacuum map screen (`501` message),
per-room/zone cleaning (those come from Roborock on the hub), push/live events (polling instead).

## Tokens and their limits

- Stored only in secure storage (`flutter_secure_storage`: iOS Keychain `first_unlock_this_device`,
  Android Keystore), never in SharedPreferences, never sent anywhere but the vendor's own API host.
- **SmartThings PATs expire after 24 hours** (issued after 2024-12-30). The app says so on the token
  screen, shows a banner when a request gets 401/403, and warns once the stored token is >= 24 h old.
  Fix: create a new token at account.smartthings.com/tokens and paste it.
- **LG ThinQ PAT + country** (connect-pat.lgthinq.com). The country must match the account's.

## Web builds and CORS

Direct mode makes the browser call `api.smartthings.com` and `api-*.lgthinq.com`. These do not send
CORS headers for arbitrary origins, so **a web build will likely be blocked**. Native iOS/Android is
the target. (Web also needs HTTPS for secure storage.) The web build remains useful for hub mode and
UI work.

## TODO: SmartThings OAuth (needs a small relay)

Long-lived SmartThings access needs the OAuth authorization-code flow with a client secret. A client
secret must not ship inside an app, so this needs a tiny relay that does the code exchange and refresh,
plus an app redirect (custom URL scheme / universal link). Sketch:

1. Relay holds the SmartThings OAuth-In app's client id/secret; exposes `/oauth/smartthings/start`
   and `/callback`, stores the refresh token per user (or hands the app a short-lived access token).
2. App opens the authorize URL in a system browser, receives `homeiot://oauth?...`, then either calls
   the relay for access tokens or refreshes through it.
3. Implement as a `TokenSupplier` (see `cloud_provider.dart`) so `SmartThingsClient` is unchanged.
   The hub side already has `OAuth2RefreshTokenProvider` (see `cloud-integrations.md`).

## Plugging in a future relay backend

1. Add `RelayBackend implements DeviceBackend` (`kind => BackendKind.relay`): devices/commands via the
   relay's API, `hasEventStream => true` with push (APNs/FCM) mapped to `BackendEvent`s, Roborock and
   OAuth handled server-side.
2. Add it to `SettingsStore.mode`, the mode pickers (setup + settings) and `HubState.selectMode`.
3. No screen or capability widget changes: they only see `Device`s with canonical capabilities.

## Keeping the capability catalog in sync

`app/lib/models/canonical_catalog.dart` is generated. After changing `hub/homehub/capabilities.py`:

```bash
cd hub && source .venv/bin/activate && python ../app/tool/gen_canonical_catalog.py
```

A test compares it against the hub fixture (`app/test/fixtures/capabilities.json`).

## Unverified

Everything above is covered by unit tests with mocked HTTP only. No real SmartThings/LG token, device
or account was used. Enum values marked ASSUMPTION in the Python adapters (LG start/stop/resume
values, Samsung `samsungce.powerCool`, Jet Bot commands) are carried over unchanged and remain
unverified on hardware.
