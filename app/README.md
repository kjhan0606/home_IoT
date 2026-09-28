# 홈 IoT — Flutter app (Phase 2)

A thin client for the **HomeHub** local gateway (`../hub`), talking to it over HTTP + WebSocket.
It targets **iOS first**, then Android; the web build is used for development and verification.

The app **never special-cases a brand**. Screens are built from the hub's brand-neutral data:
`GET /capabilities` (canonical actions, state, `uiHint`) and `GET /devices` (the capabilities each
device actually supports, plus live state). A new hub adapter or capability needs no app change.
Unknown capabilities fall back to a generic card.

## Structure

```
lib/
  main.dart                 bootstrap (SharedPreferences, Provider, reconnect to the last hub)
  app.dart                  MaterialApp (Material 3, light/dark, Korean), connect-or-list gate
  api/hub_api.dart          HubApi interface + HttpHubApi (REST, X-HomeHub-Token, /ws events)
  api/hub_discovery.dart    Bonjour discovery of _homehub._tcp (bonsoir; iOS/Android)
  models/                   Device/CapabilityInstance, CapabilitySpec, VacuumMap (+affine), HubConfig
  state/hub_state.dart      ChangeNotifier: connection, devices, catalog, live updates (auto-reconnect)
  state/settings_store.dart last hub + preferences
  l10n/ko.dart              Korean labels for canonical vocabulary (raw value when unknown)
  screens/                  connect, device list, device detail, vacuum map, settings
  widgets/capability_view.dart   uiHint -> widget dispatcher
  widgets/capabilities/     toggle, slider+mute, stepper, picker, transport, app-grid, slider,
                            color-wheel, readout, laundry-cycle, fridge-panel, vacuum-controls,
                            mop-controls, consumables-list, room-picker, map-view, generic fallback
test/                       model parsing, state, widget tests (FakeHubApi + fixtures captured from the hub)
ci/                         iOS TestFlight workflow TEMPLATE (inactive)
tool/screenshots/           headless-Chrome screenshot + live-update E2E scripts
```

State management is plain `provider` + one `ChangeNotifier`. Nothing more is needed yet.

## Features

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
- **Settings:** hub address/change/disconnect, integration status (`/integrations`, with last cloud
  errors), Roborock link (email → request code → log in with the code, or password) and unlink,
  and SmartThings/ThinQ token status with short instructions. Tokens stay on the hub.
- **UI:** Korean, Material 3, follows system light/dark.

**Stubbed or not done yet:** zoom/pan on the map; Samsung first-pairing helper; per-client auth
(the shared secret is kept in SharedPreferences, so move it to the Keychain once real auth
exists); remote access outside the LAN (Phase 4 relay); localization beyond Korean.

## Run

```bash
# SDK: Flutter stable (3.47 used here)
flutter pub get
flutter analyze && flutter test
flutter run -d chrome          # or an iPhone/Android device (see below)
```

### Demo mode (example data, no hardware)

Sample devices are served by the **hub**, as a dev-only adapter, so the app goes through its real
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

### Android

- `AndroidManifest.xml`: `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`,
  `CHANGE_WIFI_MULTICAST_STATE`, and `usesCleartextTraffic="true"` (HTTP to a LAN IP).
- Build: `flutter build apk` (needs the Android SDK, which is not installed on the dev box).
