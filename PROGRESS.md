# Progress

_Last updated: 2026-09-28_

## Where we are

**Phase 1 (local hub MVP backend) — DONE and verified end-to-end on a real LAN.**
Next session starts at **Phase 2: the Flutter app.**

## Key decisions (with rationale)

| Decision | Choice | Why |
|---|---|---|
| Overall architecture | **Local hub + thin app** | iOS sandboxes LAN scanning/sockets; hub centralizes vendor libs; works offline. App is a thin HTTP/WS client. |
| App framework | **Flutter** | One codebase for Android + iOS. |
| Capability model | **Canonical + dual mapping** to SmartThings **and** Matter | Neutral internal vocabulary; adapters normalize into it; swap local→official backend later with no app/API change. Chose "both" standards, implemented as one canonical model + two mapping tables ("Plan A": mapping/vocabulary now, real SmartThings/Matter backends later). |
| MVP target device | **Samsung TV** | Best local-control support; verifiable on the actual home TV (UN55KS8500). |
| Public/App-Store path | Deferred, but **designed for** | Cloud relay + official backends come later; adapter pattern keeps it a plug-in, not a rewrite. |

## 2026-09-28 — Cloud adapters (branch `feature/cloud-adapters`, local only)

- New canonical capabilities: `washer`, `dryer` (run/pause/stop, job, remaining
  time, `remoteControlEnabled`), `refrigeration` (temps, setpoints, doors, rapid
  cool/freeze). `vacuum` gained `setCleaningMode` + `cleaningMode(s)`. Mapped to
  SmartThings + Matter (`mappings.py`; also fixed vacuum → RvcOperationalState 0x0061).
- `adapters/smartthings.py` (REST v1, PAT via `SMARTTHINGS_TOKEN`) and
  `adapters/lg_thinq.py` (ThinQ Connect, PAT via `LG_THINQ_TOKEN`, region from
  `LG_THINQ_COUNTRY`=KR → api-kic). Both are enabled only when the token is set.
- `cloud/auth.py`: `TokenProvider` interface; PAT provider in use; OAuth2
  refresh provider implemented but not wired (TODO(oauth)).
- `linking.py` + manager: LAN/cloud dedup (MAC or kind+brand+name/model), local first
  with cloud fallback, cloud-only actions routed to cloud, aliases for cloud ids.
- Remote-start refusal (403) when the appliance's remote control is off.
- 41 pytest tests (mocked HTTP) + pyflakes clean. **Not yet run against real
  accounts.** Assumptions are listed in docs/cloud-integrations.md.
- Decision: official cloud APIs as the compliant path for appliances. LG TVs aren't
  in ThinQ Connect → need a separate local webOS adapter later.

## What's built (`hub/`)

- **Canonical capability model** (`homehub/capabilities.py`) — `power`, `volume`,
  `channel`, `mediaInput`, `mediaPlayback`, `launchApp`, `brightness`, `color`,
  `lock`, `vacuum`, `sensor`; each with actions, state schema, and a UI hint.
- **Dual standards mapping** (`homehub/mappings.py`) — canonical ⇄ SmartThings
  capability ⇄ Matter cluster. (Matter volume/media intentionally `None` — early
  Matter has no clean TV volume cluster.)
- **Discovery engine** (`homehub/discovery/`) — fuses:
  - ARP ping-sweep (`netutil.py`) → every IP + MAC, with OUI vendor lookup
    (`oui.py`, offline seed + macvendors cache; flags randomized MACs)
  - mDNS/Bonjour browse (`mdns.py`) → Apple/Cast/Samsung/HomeKit hints
  - SSDP/UPnP M-SEARCH (`ssdp.py`) → friendlyName/manufacturer
  - TCP port probe → adapter fingerprinting hints
- **Adapter pattern** (`homehub/adapters/`) — `DeviceAdapter` ABC; `registry.py`
  claims hosts + infers kinds for passive devices.
- **Samsung TV adapter** (`adapters/samsung_tv.py`) — Wake-on-LAN power-on +
  Samsung MultiScreen WebSocket (port 8002) for volume/channel/input/app-launch.
- **Control plane** (`manager.py`) — scan, persist snapshot (`store.py`), route
  canonical commands to the owning adapter.
- **API server** (`server.py`) — FastAPI REST + WebSocket, Bonjour self-advertise
  (`_homehub._tcp`), optional shared-secret auth.

## Verified (live)

- Network scan → **10 hosts discovered and classified** (router / vacuum / TV /
  set-top-box / phones-with-randomized-MAC).
- Samsung TV `192.168.45.95` **auto-claimed** by `samsung_local`; identified as
  `[TV] Samsung 8 Series (55)` / `UN55KS8500`; given 5 capabilities.
- Commands executed successfully through the full stack (API → WS → TV):
  `power.turnOn` (Wake-on-LAN, TV powered on in ~4 s), `volume.volumeDown`,
  `volume.mute`.
- Capability matrix served correctly, e.g. `power → switch → OnOff (0x6)`,
  `channel → tvChannel → Channel (0x504)`.

## Environment

- Python **3.14** (all deps install, incl. zeroconf built from source).
- Deps: fastapi, uvicorn, zeroconf, samsungtvws 3.0.5, wakeonlan, requests,
  websocket-client (`hub/requirements.txt`).
- macOS. Hub verified on the home Wi-Fi `192.168.45.0/24`.

## Open notes / small TODOs

- Samsung pairing **token file came up empty** — commands still worked (TV likely
  in a no-token/pre-authorized mode). Confirm token persistence for reliability.
- `power.turnOff` path implemented (WebSocket `KEY_POWER`) but **not yet verified**
  (deferred — someone was watching TV).
- Absolute `volume.setLevel` not implemented for Samsung (only up/down/mute);
  would need UPnP RenderingControl. Slider can come with the app.
- Bonjour registration adds ~5 s to server startup (blocking in lifespan) —
  make non-blocking if it matters.
- Randomized-MAC devices can't be vendor-identified (by design of MAC privacy).

## How to resume

1. `cd hub && source .venv/bin/activate && ./run.sh`
2. `curl -X POST localhost:8099/scan` then `GET /devices`.
3. Begin Phase 2 (Flutter app) — see `ROADMAP.md`.
