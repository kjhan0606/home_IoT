# Cloud integrations: SmartThings & LG ThinQ

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
