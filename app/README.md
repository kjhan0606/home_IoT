# 홈 IoT — Flutter app (Phase 2)

Controls Samsung SmartThings and LG ThinQ devices (and, with the optional HomeHub, more) from
iOS/Android. It targets **iOS first**, then Android; the web build is used for development and hub mode.

## Modes (how the app gets its devices)

| Mode | Server? | Notes |
|---|---|---|
| **직접 연결 / Direct cloud** (default for new installs) | none | The app calls SmartThings and LG ThinQ Connect itself with your personal tokens (kept in Keychain/Keystore). Enter them on first launch or in Settings. |
| **홈 허브 / Hub** | your own HomeHub on the LAN | HTTP + WebSocket to `../hub`. Adds Samsung TV local control, Roborock, vacuum maps. Existing behaviour, unchanged. |
| Relay (future, optional, paid) | hosted | Push notifications, Roborock, SmartThings OAuth. Not built; plugs in as another `DeviceBackend`. |

- SmartThings personal tokens **expire after 24 h**; the app warns and shows how to renew.
  OAuth (no expiry) needs a small relay and is a documented TODO.
- Web builds of direct mode will likely be blocked by the vendors' CORS policy; use iOS/Android.
- Nothing has been tried with real tokens or devices yet (unit tests use mocked HTTP).

Details, wiring and how to add a backend: **[../docs/app-backends.md](../docs/app-backends.md)**.

The app **never special-cases a brand**. Screens are built from brand-neutral data: canonical
capabilities (actions, state, `uiHint`) and each device's supported capabilities with live state.
The hub serves them; in direct mode the app builds them itself (`lib/backend/direct/`, ports of the
hub's Python adapters, with a bundled copy of the capability catalog). A new adapter or capability
needs no UI change. Unknown capabilities fall back to a generic card.

## Structure

```
lib/
  main.dart                 bootstrap (SharedPreferences, secure storage, Provider, resume last mode)
  app.dart                  MaterialApp (Material 3, light/dark, Korean), onboarding/connect/list gate
  backend/device_backend.dart   DeviceBackend interface (direct cloud | hub | future relay)
  backend/direct/           SmartThings + LG ThinQ clients (ports of the hub adapters), DirectCloudBackend
  api/hub_api.dart          HttpHubApi = the hub DeviceBackend (REST, X-HomeHub-Token, /ws events)
  api/hub_discovery.dart    Bonjour discovery of _homehub._tcp (bonsoir; iOS/Android)
  models/                   Device/CapabilityInstance, CapabilitySpec, VacuumMap (+affine), HubConfig
  state/hub_state.dart      ChangeNotifier over the active backend: devices, catalog, live updates / polling
  state/settings_store.dart mode, last hub, preferences
  state/credentials_store.dart  SmartThings/LG tokens in Keychain/Keystore (flutter_secure_storage)
  l10n/ko.dart              Korean labels for canonical vocabulary (raw value when unknown)
  screens/                  setup (onboarding), cloud accounts, hub connect, device list/detail, vacuum map, settings
  widgets/capability_view.dart   uiHint -> widget dispatcher
  widgets/capabilities/     toggle, slider+mute, stepper, picker, transport, app-grid, slider,
                            color-wheel, readout, laundry-cycle, fridge-panel, vacuum-controls,
                            mop-controls, consumables-list, room-picker, map-view, generic fallback
test/                       model parsing, state, widget tests (FakeHubApi + fixtures captured from the hub)
test/direct/                SmartThings/LG client tests with mocked HTTP, backend, state and UI tests
tool/gen_canonical_catalog.py   regenerates lib/models/canonical_catalog.dart from the hub's capabilities.py
ci/                         iOS TestFlight workflow TEMPLATE (inactive)
tool/screenshots/           headless-Chrome screenshot + live-update E2E scripts
```

State management is plain `provider` + one `ChangeNotifier`. Nothing more is needed yet.

## Features

- **Direct cloud (no server):** onboarding + Settings > 클라우드 계정 for the SmartThings token and the LG
  ThinQ token + country; devices of both clouds in one list (polled every 60 s while the app is open);
  washer/dryer remote start refused with a Korean explanation when remote control is off; an expired
  or rejected token shows a banner with a shortcut. Not available here: TV local control, Roborock, vacuum map.
- **Hub connection:** Bonjour auto-discovery (`_homehub._tcp`), manual `IP:port`, optional shared
  secret (`HOMEHUB_TOKEN` on the hub → sent as `X-HomeHub-Token`), and the last hub is remembered.
- **Device list:** grouped by kind or room (`meta.room` when an adapter provides one), online dot,
  quick power toggle, scan button (`POST /scan`), pull to refresh, live updates over `/ws` with
  automatic reconnect. Devices the hub can't control are shown in a collapsed section.
- **Device detail**, driven by capabilities:
  - **TV:** power, volume +/−, a slider only if `setLevel` exists, mute, channel (±, direct entry),
    input, playback, apps.
  - **Washer/dryer:** state, phase, remaining time, start/pause/stop. A Korean banner explains when
    remote control is off, and HTTP 403 shows "기기에서 '원격 시작' 버튼을 누른 뒤 다시 시도하세요".
  - **Fridge:** measured temperatures, setpoint ±, doors, rapid cooling/freezing.
  - **Vacuum:** status, battery, errors, start/pause/stop/dock, suction and mop options,
    consumables with reset (confirmation first), cleaning stats, and quick room chips.
  - **Map** (`GET /devices/{id}/map`): tap rooms to select them, then clean with a repeat count;
    draw up to `maxZones` rectangles and clean them; long-press to send the robot to a point. Taps are
    converted with the hub's `imageToMap` affine, so rotated or flipped maps work unchanged.
  - **Generic:** brightness, colour, lock, sensors, plus a fallback card for anything unknown.
- **IP cameras (CCTV):** camera grid on the device list, camera screen (live view, snapshot refresh, PTZ pad with hold-to-move,
  presets, resolution profile) and an add-camera screen (auto-found ONVIF cameras, or manual RTSP / MJPEG / JPEG address +
  user/password kept in secure storage). Works in direct mode with no cloud account and in hub mode. Live view uses RTSP via
  `media_kit` on iOS/Android and falls back to MJPEG, then snapshots; the web build shows snapshots only. Demo cameras can be
  added from the add-camera screen. **Untested with a real camera.** See [../docs/cameras.md](../docs/cameras.md).
- **Settings:** hub address/change/disconnect, integration status (`/integrations`, with last cloud
  errors), Roborock link (email → request code → log in with the code, or password) and unlink,
  and SmartThings/ThinQ token status with short instructions. Tokens stay on the hub.
- **UI:** Korean, Material 3, follows system light/dark.

**Stubbed or not done yet:** SmartThings OAuth (needs a relay); the paid relay backend (push, Roborock);
zoom/pan on the map; Samsung first-pairing helper; per-client auth (the hub's shared secret is still
in SharedPreferences; vendor tokens are in secure storage); localization beyond Korean.

## Run

```bash
# SDK: Flutter stable (3.47 used here)
flutter pub get
flutter analyze && flutter test
flutter run -d chrome          # or an iPhone/Android device (see below)
```

### Demo mode (example data, no hardware)

(Hub mode only.) Sample devices are served by the **hub**, as a dev-only adapter, so the app goes through its real
HTTP/WS code paths:

```bash
cd ../hub
HOMEHUB_FAKE_DEVICES=1 HOMEHUB_CORS_ORIGINS=http://localhost:8088 ./run.sh
```

This adds a TV, washer (remote start off → shows the 403 flow), fridge, robot vacuum with a
600×600 sample map (4 rooms, flipped y axis), light and door lock. Names end in "(예시)", and the app
shows an "예시 데이터" banner/chip. `HOMEHUB_CORS_ORIGINS` is needed only for the web build; native
apps don't use CORS, and it is closed by default.

Screenshots of the demo data: see `tool/screenshots/README.md`.

## iPhone

This Linux box can't build iOS. You need a **Mac with Xcode**.

### (a) Free Apple ID (personal device; re-sign every 7 days)

1. On the Mac: install Xcode (App Store), then `xcode-select --install`,
   `sudo xcodebuild -runFirstLaunch`, `brew install cocoapods`, and Flutter stable. Check with `flutter doctor`.
2. `git clone` the repo, then `cd app && flutter pub get`. The first `flutter run` or `flutter build ios`
   generates the iOS plugin integration (CocoaPods/SwiftPM) by itself.
3. `open ios/Runner.xcworkspace` → Runner target → **Signing & Capabilities**:
   check *Automatically manage signing* and pick **Team = your Apple ID (Personal Team)**.
   Bundle id: `com.kjhan0606.homeiot`. If Xcode says it's taken, change it to something unique,
   e.g. `com.<you>.homeiot`.
4. iPhone: connect it by USB, tap *Trust*, then enable **Settings › 개인정보 보호 및 보안 › 개발자 모드**
   (the phone reboots).
5. `flutter run --release` (a debug build can't be relaunched from the home screen without a debugger).
6. On the first launch, if iOS blocks the app: **Settings › 일반 › VPN 및 기기 관리** → trust your developer
   certificate.
7. When the app first searches or connects, iOS asks for **로컬 네트워크** access (the text comes from
   `NSLocalNetworkUsageDescription`). Allow it. If you denied it: **Settings › 홈 IoT › 로컬 네트워크**.
8. With a free account the app **expires after 7 days**. Re-run step 5 to re-sign. You can have at most 3 apps
   installed this way.

The hub must be running on the same Wi-Fi (`./run.sh` binds `0.0.0.0:8099` and advertises
`_homehub._tcp`). Allow port 8099 in the hub machine's firewall. If discovery finds nothing
(some routers block multicast), type the hub's IP.

### (b) TestFlight (paid Apple Developer Program, 99 USD/year)

1. Enroll, then in App Store Connect create the app with bundle id `com.kjhan0606.homeiot`.
2. Local: Xcode → Team = your paid team → `flutter build ipa --release` → open
   `build/ios/archive/Runner.xcarchive` in Xcode Organizer → *Distribute App › App Store Connect*.
   Or use **Transporter** with `build/ios/ipa/*.ipa`.
3. In App Store Connect → TestFlight, add yourself as an internal tester and install the *TestFlight* app on
   the iPhone. Builds are valid for 90 days, and no 7-day re-signing is needed.
4. CI option: `ci/github-actions-ios-testflight.yml` is an **inactive template** (manual trigger, macOS
   runner, secrets as placeholders). Copy it to `.github/workflows/`, add the secrets, and fill in
   `ios/ExportOptions.plist` (`PLACEHOLDER_TEAM_ID`, `PLACEHOLDER_APPSTORE_PROFILE_NAME`).
   Codemagic works too: point it at `app/` and reuse the same signing assets.

App Store review note: the Samsung WebSocket and Roborock integrations on the hub are unofficial.
See `../ROADMAP.md` § Legal before a public release.

### iOS configuration in this repo

- `ios/Runner/Info.plist`:
  - `NSLocalNetworkUsageDescription` (Korean)
  - `NSBonjourServices = [_homehub._tcp]`
  - `NSAppTransportSecurity.NSAllowsLocalNetworking = true` (the hub is plain HTTP on the LAN)
  - display name "홈 IoT"
- Deployment target iOS 15 (bonsoir needs ≥ 13).

- Cameras: RTSP playback needs the native `media_kit` libraries (not built on the dev box). WS-Discovery on iOS may need
  Apple's multicast networking entitlement; without it, type the camera IP.

### Android

- `AndroidManifest.xml`: `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`,
  `CHANGE_WIFI_MULTICAST_STATE`, and `usesCleartextTraffic="true"` (HTTP to a LAN IP).
- Build: `flutter build apk` (needs the Android SDK, which is not installed on the dev box).
