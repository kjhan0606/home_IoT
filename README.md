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
                                                   │   ├─ smartthings    ⬚    │
                                                   │   ├─ matter         ⬚    │
                                                   │   └─ roborock       ⬚    │
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
├── app/            Flutter thin client            (planned — next)
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
power-on + WebSocket volume/channel). Next up: the Flutter app.

Full detail in **[PROGRESS.md](PROGRESS.md)** · plan in **[ROADMAP.md](ROADMAP.md)**.

> ⚠️ The current Samsung/Roborock integrations use **unofficial local
> protocols** — fine for personal use, but a commercial App Store release must
> migrate to **official backends (SmartThings API, Matter)**. The adapter
> pattern is designed exactly for that swap. See `ROADMAP.md` § Legal.
