# home_IoT

A local-first smart-home controller. It **discovers every device on your home
network** and **controls them** through a single, uniform interface — with a
mobile app (Android/iOS) as the front end.

The core idea: represent every device as a set of **canonical capabilities**
(power, volume, brightness, lock, …) instead of brand-specific APIs, so the app
renders controls generically and new device integrations plug in without
touching the app.

## Architecture

```
┌────────────────┐        HTTP + WebSocket        ┌──────────────────────────┐
│  Flutter app   │ ─────────────────────────────▶ │   HomeHub local gateway  │
│ (Android/iOS)  │ ◀───────  live status  ─────── │        (Python)          │
│  thin client   │      (finds hub via Bonjour)   │                          │
└────────────────┘                                │  DeviceAdapter registry  │
                                                   │   ├─ samsung_local  ✅   │
                                                   │   ├─ smartthings    ✅   │
                                                   │   ├─ lg_thinq       ✅   │
                                                   │   ├─ matter         ⬚    │
                                                   │   └─ roborock       ✅   │
                                                   └──────────────────────────┘
                                                                │
                              LAN: ARP · mDNS · SSDP · vendor devices
```

**Why a local hub (not app-only)?** iOS heavily sandboxes LAN access
(scanning, raw sockets, background). A small always-on gateway sidesteps that,
centralizes vendor integrations where the libraries live, and works offline.
For a public release it gains a **cloud relay** for remote access + multi-tenant
accounts (see `ROADMAP.md`).

**Capability model.** Canonical capabilities map to **both** SmartThings
capabilities **and** Matter clusters, so today's local/unofficial adapters can
later be swapped for official cloud/Matter backends with no app or API change.

## Repository layout

```
home_IoT/
├── hub/            Python local gateway (FastAPI). See hub/README.md
│   └── homehub/    capability model, discovery, adapters, server
├── app/            Flutter thin client (iOS/Android; web for dev). See app/README.md
├── docs/           cloud-integrations.md, cameras.md (IP camera / CCTV), home-summary.md, home-automation.md, home_IoT_scenario.md (현재 상태·시나리오, 한국어), home_IoT_revenue_model.xlsx (수익 모델 초안)
├── PROGRESS.md     what's built & verified, decisions log
└── ROADMAP.md      phased plan toward App Store release
```

## Quick start (hub)

```bash
cd hub
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
./run.sh                     # http://0.0.0.0:8099
curl -X POST localhost:8099/scan          # discover devices
```

See **[hub/README.md](hub/README.md)** for the full API and examples.

### Cloud appliances (optional)

Samsung (SmartThings) and LG (ThinQ Connect) washers, dryers, fridges, robot vacuums
and Samsung TVs are available once you set a token. Nothing changes if the tokens are unset:

```bash
export SMARTTHINGS_TOKEN=...   # https://account.smartthings.com/tokens  (24 h PAT)
export LG_THINQ_TOKEN=...      # https://connect-pat.lgthinq.com
export LG_THINQ_COUNTRY=KR
./run.sh && curl -X POST localhost:8099/scan
```

### Roborock vacuums (optional, unofficial)

Link a Roborock account once (email code or password). After that the hub controls the vacuum
over the LAN when it can and falls back to Roborock's cloud. Rooms, zones, go-to, suction, mop,
consumables and a tappable map are all exposed as brand-neutral capabilities:

```bash
curl -X POST localhost:8099/integrations/roborock/request-code -H 'Content-Type: application/json' -d '{"email":"you@example.com"}'
curl -X POST localhost:8099/integrations/roborock/login        -H 'Content-Type: application/json' -d '{"email":"you@example.com","code":"123456"}'
curl -X POST localhost:8099/scan
```

Details, what works per device, limits, and the OAuth plan: **[docs/cloud-integrations.md](docs/cloud-integrations.md)**.

Tests: `pip install -r requirements-dev.txt && pytest` (from `hub/`, all HTTP mocked).

## App (Flutter)

The app works **without a server** by default: it talks to SmartThings and LG ThinQ directly with your
personal tokens (direct-cloud mode). The hub stays available as an optional mode for TV local control,
Roborock and vacuum maps, and a future paid relay can plug in as a third backend.
See **[docs/app-backends.md](docs/app-backends.md)**.

```bash
cd app && flutter pub get && flutter test
flutter run -d chrome     # or an iPhone: see app/README.md (free Apple ID or TestFlight)
```

To try it without hardware, start the hub in **demo mode** (example devices, dev only):
`HOMEHUB_FAKE_DEVICES=1 HOMEHUB_CORS_ORIGINS=http://localhost:8088 ./run.sh`.
Details are in **[app/README.md](app/README.md)**.

### IP cameras / CCTV (LAN only)

Add ONVIF / RTSP / MJPEG cameras: live view, snapshot, PTZ. Works in direct mode (no account needed) and through the hub.
Auto-discovery uses ONVIF WS-Discovery. **Not tested with a real camera yet.** Never expose camera ports to the internet.
See **[docs/cameras.md](docs/cameras.md)**.

## Resume on another machine

Pick up the project anywhere from a fresh clone:

```bash
git clone https://github.com/kjhan0606/home_IoT.git
cd home_IoT/hub
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
./run.sh                                  # http://0.0.0.0:8099
curl -X POST localhost:8099/scan          # discover devices on the LAN
curl localhost:8099/devices               # list them
```

`hub/data/` (device snapshot, Samsung pairing tokens) is git-ignored, so it is
**not** cloned — it regenerates on the first `/scan`, and the TV re-pairs on the
first command (accept the on-screen prompt with the remote).

Then continue the work:
- **[PROGRESS.md](PROGRESS.md)** → "How to resume" + the decisions log and
  what's already verified.
- **[ROADMAP.md](ROADMAP.md)** → next up is **Phase 2 — the Flutter app**.

## Status

MVP hub backend is **built and verified end-to-end on a real LAN** (10 devices
discovered/classified; a Samsung TV auto-claimed and controlled — Wake-on-LAN
power-on + WebSocket volume/channel). **SmartThings, LG ThinQ and Roborock**
adapters are implemented and unit-tested with mocked APIs, but not yet tried
against real accounts. **Phase 2 Flutter app** (branch `feature/flutter-app`) is built:
it runs as a web build against the hub, is tested with a fake API, and is verified end to end
with demo data. It has not yet been run on an iPhone.

Full detail in **[PROGRESS.md](PROGRESS.md)** · plan in **[ROADMAP.md](ROADMAP.md)**.

> ⚠️ The current Samsung/Roborock integrations use **unofficial local
> protocols** — fine for personal use, but a commercial App Store release must
> migrate to **official backends (SmartThings API, Matter)**. The adapter
> pattern is designed exactly for that swap. See `ROADMAP.md` § Legal.
