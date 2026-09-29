# CLAUDE.md — read this first

You (Claude Code) are **resuming an in-progress project**, not starting fresh.
This file is your quick briefing. For depth, read **PROGRESS.md** (status +
decisions log) and **ROADMAP.md** (the plan). User-facing overview is README.md.

## What this project is

`home_IoT` — a **local-first universal smart-home controller**: a Python **local
hub** discovers devices on the home LAN and controls them through a **canonical
capability model**; a **Flutter app** (Android/iOS) is a thin client over the
hub's HTTP/WS API. End goal: ship on the App Store.

## Resume in ~30 seconds

```bash
cd hub
python3 -m venv .venv && source .venv/bin/activate   # if .venv missing
pip install -r requirements.txt
./run.sh                                   # http://0.0.0.0:8099
curl -X POST localhost:8099/scan           # discover devices on THIS network
curl localhost:8099/devices                # list them
```

`hub/data/` is git-ignored (device snapshot + Samsung pairing tokens) — it
regenerates on first `/scan`.

## Current status → your next task

- **Phase 1 (local hub MVP backend): DONE and verified** on the original home
  LAN. Discovery + canonical model + Samsung TV adapter (WoL power-on + WebSocket
  control) all work through the API.
- **Phase 2 — the Flutter app** (`app/`) is built (branch `feature/flutter-app`):
  thin client, capability-driven UI, tested with a fake API and verified on web.
  Next: run it on the iPhone (needs a Mac), then real devices. See app/README.md.
- Flutter SDK on the Linux dev box: `~/flutter` (stable). Web builds only; no
  Android SDK, and iOS can't be built there.

## Architecture you MUST respect

Everything routes through the **canonical capability contract**. This is the
whole point of the design — do not bypass it.

- `hub/homehub/capabilities.py` — canonical capabilities (`power`, `volume`, …):
  actions + state schema + UI hint. **The app renders generically from this.**
- `hub/homehub/mappings.py` — canonical ⇄ **SmartThings** capability ⇄ **Matter**
  cluster. We deliberately support **both** standards via one canonical model +
  two mapping tables (the user chose this; "Plan A" = mapping/vocabulary now,
  real SmartThings/Matter *backends* later).
- `hub/homehub/adapters/base.py` — `DeviceAdapter` ABC. To add a device
  integration, **write a new adapter** satisfying this contract; never special-
  case a brand in the app, manager, or API. `samsung_tv.py` is the reference.
- Rule of thumb: **new device support = new adapter**, and the app/API don't
  change.

## Repo map

```
hub/homehub/
  capabilities.py      canonical model            mappings.py   ST/Matter matrix
  models.py            Device / DiscoveredHost    netutil.py    LAN/WoL/ARP
  discovery/           engine, mdns, ssdp, oui    manager.py    control plane
  adapters/            base, registry, samsung_tv, cloud_base,
                       smartthings, lg_thinq, roborock   server.py  FastAPI + WS + Bonjour
  cloud/               auth (TokenProvider), errors, roborock_backend   linking.py  LAN<->cloud dedup
  secret_store.py      0600 per-integration secrets   vacuum_map.py  map metadata/transform
hub/tests/             pytest (mocked vendor HTTP): `pytest` from hub/
docs/cloud-integrations.md  tokens, OAuth flow, limits, assumptions
app/                   Flutter app: lib/{backend,api,models,state,screens,widgets}, test/
                       (backend/direct = Dart ports of the SmartThings/LG adapters; see docs/app-backends.md)
                       (fake API + fixtures captured from the hub), ci/ (iOS template)
hub/homehub/adapters/demo.py   dev-only sample devices (HOMEHUB_FAKE_DEVICES=1)
PROGRESS.md ROADMAP.md README.md
```

## Constraints & gotchas

- **Different network now.** Device IPs/MACs in PROGRESS.md (e.g. `192.168.45.x`,
  the TV's MAC) are from the *original* home LAN. On this machine, **re-scan** —
  the device set will differ. Samsung control only works if a Samsung TV is
  actually present on this LAN.
- **Legal / App Store:** the Samsung (WebSocket) and Roborock (python-roborock)
  integrations are **unofficial/reverse-engineered** — OK for personal use, must
  migrate to **official SmartThings API / Matter** before commercial release.
  The adapter pattern makes that a swap, not a rewrite. (ROADMAP.md § Legal.)
- **Matter reality:** Matter doesn't cover TV/media and only controls certified
  devices; it's one adapter among several, not the whole app.
- **Never commit** `hub/data/` (tokens, home-network details) or `.venv/` — both
  are git-ignored; keep it that way.
- **WoL** must bind to the LAN interface + subnet broadcast (multi-interface/VPN
  boxes fail on `255.255.255.255`) — see `netutil.wake_on_lan`.
- Env: Python **3.14** works (zeroconf builds from source). Bonjour registration
  adds ~5 s to server startup.

## How the user works (learned)

- Wants to **discuss approach before big builds**; confirm design forks, don't
  assume. Decisions get recorded in PROGRESS.md.
- Cares about **App-Store legality** and a **universal/general-purpose** design.
- Verify against **real devices** when possible; don't send stray commands to a
  TV someone is watching — ask first.

## Verifying changes

- App: `cd app && flutter analyze && flutter test`. UI rule: pick widgets by
  `uiHint` or capability key only, never by adapter/vendor/brand.
- The app has a `DeviceBackend` abstraction (direct cloud | hub | future relay). When you change a
  Python cloud adapter's mapping, mirror it in `app/lib/backend/direct/`; when you change
  `capabilities.py`, run `app/tool/gen_canonical_catalog.py`.

- Import smoke test: `python -c "import homehub.server"` from `hub/` (venv on).
- Live: `POST /scan` → `GET /devices` → send a safe command
  (`volume.volumeDown`) to a controllable device.
- Backup: commit + `git push origin main` (gh auth via keyring).
