# Roadmap

Goal: a **universal, local-first smart-home controller** with an Android/iOS app,
eventually shippable on the App Store.

Legend: ✅ done · 🔜 next · ⬚ planned

---

## Phase 1 — Local hub MVP ✅

Discovery + canonical capability model + Samsung TV local control + HTTP/WS API.
Verified end-to-end on a real LAN. (Details in `PROGRESS.md`.)

## Phase 2 — Flutter thin client 🔜

The immediate next step.

- [ ] Scaffold Flutter app (`app/`); install Flutter SDK.
- [ ] **Hub auto-discovery** on LAN via Bonjour (`_homehub._tcp`); manual
      IP fallback.
- [ ] **Device list** screen — kinds, reachability, controllable badge.
- [ ] **Generic capability rendering** — one widget per canonical capability
      (toggle / slider+mute / stepper / picker / app-grid), driven by the
      `/capabilities` `uiHint`. Adding an adapter later needs **no app change**.
- [ ] **Samsung TV control** screen end-to-end: power (WoL on / off),
      volume, channel, input, app launch.
- [ ] Live updates via WebSocket `/ws`.
- [ ] First-run: pairing helper for the Samsung "Allow device?" prompt.

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

- [ ] **SmartThings cloud adapter** (official Samsung API) — replaces the
      unofficial local TV control for compliant shipping. Vocabulary already
      matches (canonical modeled on SmartThings capabilities).
- [ ] **Matter controller adapter** — lights/plugs/locks/sensors/newer vacuums.
      iOS: Apple Matter framework; Android: Google Home APIs; bridged to Flutter
      via platform channels. Needs a Thread Border Router in-home for Thread.
- [ ] **Roborock adapter** (needs one-time cloud token extraction).
- [ ] Media adapters (AirPlay / Chromecast / DIAL) for TVs/speakers/IPTV that
      Matter doesn't cover.

---

## Legal / App Store notes ⚠️

- Current Samsung (WebSocket) and future Roborock (miIO) integrations are
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
