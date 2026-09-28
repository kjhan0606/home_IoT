# Roadmap

Goal: a **universal, local-first smart-home controller** with an Android/iOS app,
eventually shippable on the App Store.

Legend: ✅ done · 🔜 next · ⬚ planned

---

## Phase 1 — Local hub MVP ✅

Discovery + canonical capability model + Samsung TV local control + HTTP/WS API.
Verified end-to-end on a real LAN. (Details in `PROGRESS.md`.)

## Phase 2 — Flutter thin client ✅ (built; iPhone run pending)

Branch `feature/flutter-app`. See `app/README.md`.

- [x] Scaffold Flutter app (`app/`); Flutter SDK installed (stable 3.47).
- [x] **Hub auto-discovery** via Bonjour (`_homehub._tcp`, bonsoir); manual
      IP fallback; optional shared secret; last hub remembered.
- [x] **Device list**: kind/room groups, reachability, quick power toggle, scan,
      pull to refresh.
- [x] **Generic capability rendering**: one widget per `uiHint`, plus a generic fallback.
      Adding an adapter later needs **no app change**.
- [x] TV remote, laundry (remote-start 403 flow), fridge, vacuum (+ map: rooms,
      zones, go-to), light/lock/sensor.
- [x] Live updates via WebSocket `/ws` (auto-reconnect).
- [x] Settings: integrations status, Roborock link/unlink, ST/ThinQ token status.
- [x] Tests (analyze clean, widget tests with a fake API) + web E2E with demo data.
- [ ] **Run on the iPhone** (Mac + Xcode; free Apple ID or TestFlight). Verify
      the local-network prompt and Bonjour on the device.
- [ ] First-run: pairing helper for the Samsung "Allow device?" prompt.
- [ ] Map zoom/pan; Keychain storage for the hub secret once real auth exists.

## Phase 3 — Hardening ⬚

- [ ] Real auth on the hub (per-client tokens; replace dev shared-secret).
- [ ] Robust state/refresh; absolute volume via UPnP; power-state truth.
- [ ] Adapter test suite + fake device for CI.
- [ ] Package the hub as a **Docker image** / installable agent (Raspberry Pi,
      NAS, mini-PC) — the "always-on device" story.
- [ ] Confirm/repair Samsung token persistence.

## Phase 4 — Public service (remote access + multi-tenant) ⬚

Turns the personal hub into a service. See README "Why a local hub".

- [ ] **Cloud relay/broker**: hub keeps an **outbound** WS/MQTT connection;
      app reaches the hub through the cloud. **No port-forwarding** (breaks on
      CGNAT, insecure). Model: Home Assistant/Nabu Casa, SmartThings.
- [ ] User accounts + identity; **hub claiming/pairing** to an account.
- [ ] **Tenant isolation** (one user can't reach another's hub).
- [ ] End-to-end encryption on the relay.
- [ ] Onboarding UX for installing/registering a hub.

## Phase 5 — Official & universal backends ⬚

New adapters satisfying the **same canonical contract** — the app never changes.

- [x] **SmartThings cloud adapter** (official Samsung API) — PAT auth, TV +
      washer/dryer/fridge/vacuum, LAN dedup with local-first fallback.
      (`feature/cloud-adapters`; mocked tests only so far)
- [x] **LG ThinQ Connect adapter** — washer/dryer/fridge/robot vacuum (no TVs in
      that API).
- [ ] Verify both on real accounts; wire **OAuth2** for SmartThings (24 h PATs).
- [ ] LG webOS TV local adapter; washtower/combo + more appliance types.
- [ ] **Matter controller adapter** — lights/plugs/locks/sensors/newer vacuums.
      iOS: Apple Matter framework; Android: Google Home APIs; bridged to Flutter
      via platform channels. Needs a Thread Border Router in-home for Thread.
- [x] **Roborock adapter**: python-roborock, one-time cloud login (email code/password),
      LAN first with cloud fallback, rooms/zones/go-to/fan/mop/consumables/map.
      (`feature/roborock`; mocked tests only so far)
- [ ] Verify Roborock on a real vacuum; app UI for the map (tap rooms, draw zones).
- [ ] Media adapters (AirPlay / Chromecast / DIAL) for TVs/speakers/IPTV that
      Matter doesn't cover.

---

## Legal / App Store notes ⚠️

- Current Samsung (WebSocket) and Roborock (python-roborock: cloud login + local/MQTT) integrations are
  **reverse-engineered, unofficial** protocols. Fine for personal use; a
  **commercial** release risks vendor ToS violations.
- Compliant path before shipping: **SmartThings partner API** for Samsung, and
  **Matter** for the generic device categories.
- **Matter reality check:** Matter only controls Matter-certified devices, and
  **TV/media is largely out of Matter's scope** (handled by AirPlay/Cast/
  SmartThings). So this product is inherently a **multi-protocol aggregator**,
  not a pure-Matter app. Matter is one adapter among several, best for
  lights/plugs/locks/sensors.
- Get explicit user consent for scanning/controlling their network; secure the
  relay; isolate tenants.

## Guiding principle

Everything routes through the **canonical capability contract**. Discovery,
manager, API, and app depend only on it — never on a device's real protocol.
That's what makes "local unofficial → official cloud/Matter" a plug-in swap
instead of a rewrite.
