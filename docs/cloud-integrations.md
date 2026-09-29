# Cloud integrations: SmartThings, LG ThinQ & Roborock

> The Flutter app can also call SmartThings and LG ThinQ directly, without the hub: it has Dart ports of these
> two adapters (`app/lib/backend/direct/`). See [app-backends.md](app-backends.md).

Two cloud adapters bring Samsung and LG appliances into the same canonical model
as LAN devices: `hub/homehub/adapters/smartthings.py` and `hub/homehub/adapters/lg_thinq.py`.
An adapter is **enabled only when its token env var is set**. With no tokens set,
the hub runs exactly as before (LAN only).

| Env var | Default | Purpose |
|---|---|---|
| `SMARTTHINGS_TOKEN` | — | SmartThings Personal Access Token (enables `smartthings`) |
| `SMARTTHINGS_API_BASE` | `https://api.smartthings.com/v1` | override (tests/proxy) |
| `LG_THINQ_TOKEN` | — | LG ThinQ Connect PAT (enables `lg_thinq`) |
| `LG_THINQ_COUNTRY` | `KR` | `x-country`; picks the region (KR → `api-kic`) |
| `LG_THINQ_CLIENT_ID` | generated `homehub-<uuid>`, saved in `hub/data/tokens/` | `x-client-id` |
| `LG_THINQ_API_BASE` / `LG_THINQ_API_KEY` | derived / key published in LG's SDK | overrides |

```bash
export SMARTTHINGS_TOKEN=...   LG_THINQ_TOKEN=...   LG_THINQ_COUNTRY=KR
./run.sh
curl -X POST localhost:8099/scan              # LAN + cloud  (?lan=false for cloud only)
curl localhost:8099/integrations              # enabled flags + last cloud errors
curl localhost:8099/devices
```

## Getting tokens

**SmartThings PAT**
1. Go to https://account.smartthings.com/tokens and sign in with the Samsung account that owns the devices.
2. Click *Generate new token*. Select scopes **Devices: List/See all devices (`r:devices:*`)** and
   **Control all devices (`x:devices:*`)**. Add Locations read if you like.
3. Copy the token right away (it is shown only once) → `SMARTTHINGS_TOKEN`.
4. ⚠️ PATs created since 2024-12-30 **expire after 24 h**. That's fine for testing. For continuous
   use, switch to OAuth (see below).

**LG ThinQ PAT**
1. Go to https://connect-pat.lgthinq.com and sign in with your LG ThinQ account.
2. *Create new token*. Enable the device-list, device-state and device-control scopes.
3. Copy it → `LG_THINQ_TOKEN`. Set `LG_THINQ_COUNTRY` to the **account's** country (e.g. `KR`).

## What works

| Device | SmartThings (Samsung etc.) | LG ThinQ Connect |
|---|---|---|
| TV | power on/off/toggle, volume set/up/down, mute, channel up/down/set, input select, playback | **not offered by the ThinQ Connect API** (webOS needs a local adapter) |
| Washer | state/job/remaining time/remote flag; start/pause/stop | same; start=`START`, pause=`STOP`, stop=`POWER_OFF`* |
| Dryer | same as washer | same as washer |
| Refrigerator | fridge/freezer measured temp + setpoints, door open (per compartment), rapid cool/freeze | setpoints (no measured temp in API), door, express cool / rapid freeze* |
| Robot vacuum | status, battery, cleaning mode; start/pause/stop/dock/setCleaningMode* | status, battery, job mode (read); start (auto-RESUME/WAKE_UP)/pause/dock |

`*` = based on published enum values or the official SDK. Not yet verified on real hardware (see "Assumptions").

**Remote start safety:** `washer|dryer.start` re-reads the live remote-control flag
(`remoteControlStatus` / `remoteControlEnable`). If it is off, the command is refused with
**HTTP 403** and asks the user to press *Remote Start* on the appliance. LG's error `2301` maps to the same 403.

**LAN + cloud de-duplication:** if the same TV is found on the LAN (`samsung_local`) and
in SmartThings, `/devices` shows **one** entry. They are linked by MAC, or by kind + brand + name / model-number prefix
(ambiguous matches stay separate). Local control is tried first, and the hub falls back to
the cloud if the local path fails. Actions only the cloud has (e.g. `volume.setLevel`) go through the cloud.
The cloud id (`smartthings:<id>`) remains a valid alias.

## Known limits
- Devices must first be **registered in the vendor app** (SmartThings / LG ThinQ). The hub can't onboard appliances.
- The cloud path needs **internet access** and depends on vendor uptime and rate limits. New SmartThings PATs
  have lower `/devices` rate limits.
- Remote start must be **enabled on the appliance** by the user. Many appliances turn that flag off again after each cycle or when the door opens.
- Some vendor-app-only features are not exposed: course/cycle selection and options, detergent,
  maps/zones, fridge ice maker/filters, and Samsung `samsungce.*` extras beyond what's listed.
- LG: washtower combo (`DEVICE_WASHTOWER`), kimchi fridge, styler etc. are listed but not controllable yet.
  Newer Samsung Jet Bots that only expose `samsungce.robotCleanerOperatingState` are not handled yet.

## Assumptions / unverified details
- **LG endpoints and headers** follow LG's official Apache-2.0 SDK `thinq-connect/pythinqconnect`
  (`thinq_api.py`) and the ThinQ Connect PAT docs. The developer-site API reference is JS-rendered and was
  not machine-readable, so the SDK is the primary source.
- **LG enum values**: `washerOperationMode`/`dryerOperationMode` START/STOP/POWER_OFF (we treat STOP
  as pause), `cleanOperationMode` START/PAUSE/HOMING/RESUME/WAKE_UP, fridge `expressFridge` = express
  cool, `rapidFreeze` (or older `expressMode`) = express freeze. The adapter reads each device's
  `/profile` and only exposes actions whose values are writable.
- **SmartThings vacuum** commands use `setRobotCleanerMovement(cleaning|pause|homing)` and
  `setRobotCleanerCleaningMode(stop|auto|…)`, following the capability definitions.
  `samsungce.powerCool/powerFreeze` are assumed to have `activated` + `activate/deactivate`.
  Neither has been tested on real hardware.

## OAuth2 (planned: needed for long-lived and multi-user access)

The adapters get tokens from a `TokenProvider` (`hub/homehub/cloud/auth.py`). `EnvTokenProvider` (PAT) is
used today. `OAuth2RefreshTokenProvider` is already implemented (refreshes, rotates single-use refresh
tokens, stores them in `hub/data/tokens/`, mode 600) but **not wired in yet** (see `TODO(oauth)` there).

SmartThings authorization-code flow (developer.smartthings.com → Service integrations):
1. Create an **API Access (OAuth-In) app**: SmartThings Developer Console or `smartthings apps:create`.
   Register a redirect URI (e.g. `https://<hub-or-relay>/oauth/smartthings/callback`) and scopes
   `r:devices:* x:devices:*` (+ `r:locations:*`). You get a **client id + client secret**.
2. Send the user to
   `https://api.smartthings.com/v1/oauth/authorize?client_id=…&response_type=code&redirect_uri=…&scope=r:devices:*%20x:devices:*&state=<random>`.
3. After Samsung-account login and consent, SmartThings redirects to `redirect_uri?code=…&state=…`. Verify `state`.
4. Exchange the code: `POST https://api.smartthings.com/v1/oauth/token` (HTTP Basic client_id:secret,
   form `grant_type=authorization_code&code=…&client_id=…&redirect_uri=…`) →
   `OAuth2RefreshTokenProvider.exchange_authorization_code()`.
5. The access token lasts about 24 h and the refresh token 30 days (single use). The provider refreshes with
   `grant_type=refresh_token` before expiry or after a 401 and stores the new pair.
6. Remaining TODO: a hub route for steps 2–4, selecting the provider in `adapters/registry.py` when
   `SMARTTHINGS_CLIENT_ID/SECRET` are set, and per-user storage once the cloud relay exists.

LG: individual use is PAT-only. LG's OAuth (authorization code) is for ThinQ **Business/partner** services
and needs a partnership agreement. The same `TokenProvider` interface would host it.

---

## Roborock (local LAN first, cloud fallback; unofficial)

`hub/homehub/adapters/roborock.py` (a `CloudAdapter`) + `hub/homehub/cloud/roborock_backend.py`,
built on the open-source **[python-roborock](https://github.com/Python-roborock/python-roborock)**
library (pinned `python-roborock==7.12.0`; it pulls in `vacuum-map-parser-roborock` and Pillow).
Unlike SmartThings/ThinQ there is no env-var token. You link the account once through the hub API.

### Linking (one-time cloud login)

```bash
# 1. ask Roborock to email a verification code to your Roborock-app account
curl -X POST localhost:8099/integrations/roborock/request-code \
  -H 'Content-Type: application/json' -d '{"email":"you@example.com"}'
# 2. log in with the code (or {"email":..., "password":...} for password login)
curl -X POST localhost:8099/integrations/roborock/login \
  -H 'Content-Type: application/json' -d '{"email":"you@example.com","code":"123456"}'
# 3. pull the vacuums in (LAN + cloud)
curl -X POST localhost:8099/scan
curl localhost:8099/integrations/roborock      # linked?, masked account, device list
curl -X POST localhost:8099/integrations/roborock/unlink   # deletes stored credentials
```

These endpoints require the `X-HomeHub-Token` header when `HOMEHUB_TOKEN` is set, like the other mutating routes.
The login response and `GET /integrations/roborock` return a **masked** email only.

**What is stored and where:** `hub/data/tokens/roborock.json` (directory `0700`, file
`0600`, written atomically). It holds the Roborock `user_data` (session token + MQTT credentials),
the regional base URL, and the per-device **local keys** (needed for LAN control).
The library's own cache (`roborock_cache.bin`, also `0600`) sits next to it. **The password
is never stored**. Neither the code nor the tokens are logged, and a test checks both.
`unlink` deletes both files and removes the devices on the next scan.

### Transport

The library's V1 RPC channel tries the **local LAN** connection first (TCP 58867, using the
device's local key). If the vacuum isn't reachable locally, it falls back to **cloud MQTT**.
Each command response reports which transport was used (`"transport": "local"|"cloud"`).
Maps always come over the cloud (the library fetches them through MQTT).

LAN/cloud dedup: a Roborock found by the LAN scan (`infer_kind` → vacuum via the Roborock OUI
/ miio mDNS) is merged with the cloud-listed device by MAC, the vendor-reported IP, or
brand+name/model (same `linking.py` logic as SmartThings). The app sees one device.

### What works (all brand-neutral capabilities; only what the model supports is offered)

| Capability | Actions / state | Roborock command | Matter / SmartThings mapping |
|---|---|---|---|
| `vacuum` | start (resumes a paused room/zone job), pause, stop, dock; status, battery, `error`, `dockError` | `app_start`, `resume_segment_clean`, `resume_zoned_clean`, `app_pause`, `app_stop`, `app_charge` | RvcOperationalState / robotCleanerMovement |
| `roomCleaning` | `cleanRooms {roomIds, repeat}`; state `rooms[{id,name}]` | `app_segment_clean [{"segments":[..],"repeat":n}]` | ServiceArea 0x0150 / — |
| `zoneCleaning` | `cleanZones {zones:[[x1,y1,x2,y2],..], repeat}` (map coords, ≤5 zones) | `app_zoned_clean [[x1,y1,x2,y2,rep],..]` | — (ServiceArea has no ad-hoc zones) |
| `goTo` | `goTo {x, y}` (map coords) | `app_goto_target [x,y]` | — |
| `fanSpeed` | `setLevel {level}`; `levels` are the model's own names (e.g. quiet/balanced/turbo/max) | `set_custom_mode [code]` | RvcCleanMode 0x0055 / robotCleanerTurboMode |
| `mopping` | `setWaterLevel {level}`, `setMopMode {mode}`, each only if the model has it | `set_water_box_custom_mode`, `set_mop_mode` | RvcCleanMode 0x0055 / — |
| `consumables` | `reset {id}`; items mainBrush, sideBrush, filter, sensors (+ mopRoller, read-only) with used hours and remaining % | `reset_consumable [attr]` | HepaFilterMonitoring 0x0071 (filter) / — |
| `cleaningStats` | `areaM2`, `durationSeconds` of the current/last run | from `get_status` | — |
| `vacuumMap` | see the map endpoints below | `get_map_v1` via the library | — |

Unsupported actions, unknown room ids, or unknown level names are refused with HTTP 400
before anything is sent. Devices on newer protocols (A01/B01, e.g. some Qrevo/Saros/Zeo models)
are **listed but not controllable** (`controllable: false`, `meta.note`).

### Map endpoints

- `GET /devices/{id}/map.png`: the rendered map (PNG, from the library's map parser).
- `GET /devices/{id}/map?image=true|false`: JSON metadata (+ `image.pngBase64` when `image=true`, and `imageUrl`):
  - `image {width, height, format}`, `mapName`
  - `rooms[{id, name, bbox:{map:{x0,y0,x1,y1}, image:{...}}}]`: ids match `roomCleaning.rooms`
  - `robot` / `dock`: `{map:{x,y,angle?}, image:{x,y}}`
  - `transform.mapToImage` / `transform.imageToMap`: 2×3 affine matrices `[[a,b,c],[d,e,f]]`
    (`u = a·x + b·y + c`, `v = d·x + e·y + f`), fitted from the parser's calibration points
    (also returned as `calibrationPoints`). Rotated maps work too.

The app takes a tap or drawn rectangle in image pixels, applies `imageToMap`, and sends the result as
`goTo` / `cleanZones`. For a room tap it hit-tests `rooms[].bbox.image`. Map coordinates are the robot's
native units (mm; the dock is usually near 25500,25500). The last map is cached, so
`map.png` right after `map` doesn't refetch (`?cached=false` forces a refetch).

### Limits & caveats

- **Unofficial, reverse-engineered API.** Roborock can break it at any time with firmware or
  server changes. When it breaks, update `python-roborock` (check its changelog; the pin is deliberate).
- Needs a **one-time cloud login**. Login and home-data calls are rate limited by the library/server
  (HTTP 429 from the hub when hit). After that, day-to-day control is local when possible.
- If Roborock asks you to accept a new user agreement, login fails until you accept it in the Roborock app.
- **App Store:** shipping reverse-engineered vendor protocols in a commercial app risks ToS problems.
  Keep this a personal/hub-side feature; the compliant long-term route is Matter RVC
  (newer Roborock models are Matter-certified: RvcRunMode/RvcCleanMode/RvcOperationalState/ServiceArea),
  which the canonical capabilities already map to.

### Assumptions / unverified (no real Roborock device was available)

- Everything is tested with the library/network mocked. The local→cloud fallback test uses the
  library's real `RpcChannel` with stub transports. Map metadata was checked against the real
  `vacuum-map-parser` calibration math (rotations 0°/90°), not a real device map.
- The `repeat` key inside `app_segment_clean` params follows the Roborock app payload, but older
  firmware may ignore it (the plain `[ids]` form doesn't carry repeat).
- Zone/go-to are offered on every V1 model that reports a map. Very old models may refuse them.
- Consumable lifetimes (main brush 300 h, side brush 200 h, filter 150 h, sensors 30 h) follow the
  common Roborock defaults. Some models differ.

### Room cleaning on SmartThings / ThinQ vacuums

Not mapped, on purpose. The standard SmartThings robot-cleaner capabilities (`robotCleanerMovement`,
`robotCleanerCleaningMode`, `robotCleanerTurboMode`) have no rooms or zones. Samsung's
`samsungce.robotCleaner*` map capabilities are undocumented and couldn't be verified. LG ThinQ
Connect's robot-cleaner profile exposes only run state, mode, and battery. If either API gains
documented room control, the adapter only needs to fill in the same `roomCleaning` capability.
