# HomeHub — Local Gateway

Local-first smart-home hub. Discovers devices on the home LAN and controls them
through a **canonical capability model** that maps to both **SmartThings
capabilities** and **Matter clusters**, so integrations can later swap from
local/unofficial protocols to official cloud/Matter backends without changing
the API or the mobile app.

The Flutter app is a thin client over this gateway's HTTP + WebSocket API; the
hub advertises itself on the LAN via Bonjour (`_homehub._tcp`).

## Architecture

```
Flutter app  ──HTTP/WS──▶  HomeHub gateway (this)  ──▶  DeviceAdapter
                                                          ├─ samsung_local (WoL + WS)   [MVP]
                                                          ├─ smartthings  (cloud, SMARTTHINGS_TOKEN)
                                                          ├─ lg_thinq     (cloud, LG_THINQ_TOKEN)
                                                          ├─ matter             (later)
                                                          └─ roborock           (later)
```

- **capabilities.py** — canonical capability model (`power`, `volume`, `channel`, …)
- **mappings.py** — canonical ⇄ SmartThings ⇄ Matter matrix
- **discovery/** — ARP sweep + mDNS + SSDP + OUI vendor lookup → `DiscoveredHost`
- **adapters/** — `DeviceAdapter` contract; `samsung_tv.py` is the first adapter
- **manager.py** — control plane: scan, persist, route commands to adapters
- **server.py** — FastAPI HTTP/WS API + Bonjour advertisement

## Run

```bash
cd hub
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
./run.sh                      # serves on 0.0.0.0:8099
```

Optional env: `HOMEHUB_HTTP_PORT`, `HOMEHUB_TOKEN` (shared-secret auth),
`HOMEHUB_DATA` (state dir), `HOMEHUB_NAME`, and for cloud adapters
`SMARTTHINGS_TOKEN`, `LG_THINQ_TOKEN`, `LG_THINQ_COUNTRY` (default `KR`). Roborock needs no env var;
link it through `/integrations/roborock/*` (secrets go to `data/tokens/roborock.json`, mode 0600). See
[../docs/cloud-integrations.md](../docs/cloud-integrations.md).

Tests: `pip install -r requirements-dev.txt && pytest` (vendor HTTP mocked with `responses`).

## API

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | liveness + device count |
| GET | `/capabilities` | canonical model + standards matrix |
| GET | `/integrations` | adapters, enabled flags, last cloud errors |
| POST | `/scan?lan=true&cloud=true` | LAN discovery and/or cloud account sync |
| GET | `/devices` | list devices (controllable + passive) |
| GET | `/devices/{id}` | one device |
| POST | `/devices/{id}/refresh` | refresh live state |
| POST | `/devices/{id}/commands` | `{capability, action, params}` |
| GET | `/devices/{id}/map` | vacuum map metadata (rooms+bboxes, robot/dock, pixel↔map transform) + base64 PNG |
| GET | `/devices/{id}/map.png` | rendered vacuum map |
| GET | `/integrations/roborock` | Roborock link status (masked account, devices) |
| POST | `/integrations/roborock/request-code` | `{email}`: email a login code |
| POST | `/integrations/roborock/login` | `{email, code}` or `{email, password}`: link account |
| POST | `/integrations/roborock/unlink` | delete stored Roborock credentials |
| WS | `/ws` | live device/event push |

### Example

```bash
# discover
curl -X POST localhost:8099/scan

# power on the TV (Wake-on-LAN)
curl -X POST "localhost:8099/devices/samsung_local:<mac>/commands" \
  -H 'Content-Type: application/json' \
  -d '{"capability":"power","action":"turnOn"}'

# volume down
curl -X POST "localhost:8099/devices/samsung_local:<mac>/commands" \
  -H 'Content-Type: application/json' \
  -d '{"capability":"volume","action":"volumeDown"}'
```

## Status

- [x] Discovery (ARP + mDNS + SSDP + OUI)
- [x] Canonical capability model + SmartThings/Matter mapping
- [x] Samsung TV adapter (WoL power-on, WS volume/channel/input/app)
- [x] HTTP + WS API, Bonjour advertisement
- [ ] Flutter thin client
- [ ] Cloud relay (remote access, multi-tenant) — for App Store release
- [x] SmartThings + LG ThinQ cloud adapters (PAT auth; washer/dryer/fridge/vacuum/TV), LAN↔cloud dedup
- [x] Roborock adapter (python-roborock 7.12; LAN first → cloud MQTT; rooms, zones, go-to, fan, mop, consumables, map), mocked tests only
- [ ] OAuth2 wiring for SmartThings (provider exists; route + registry TODO)
- [ ] Matter controller adapter
