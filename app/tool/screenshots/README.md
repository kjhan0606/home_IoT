# Screenshot / E2E scripts (dev only)

Drive the **web build** in headless Chrome against a hub in demo mode
(`HOMEHUB_FAKE_DEVICES=1`). **All screens show example data.**

```bash
# 1) hub with sample devices; allow the web origin (CORS is closed by default)
cd hub && HOMEHUB_DATA=/tmp/hh-demo HOMEHUB_FAKE_DEVICES=1 \
  HOMEHUB_CORS_ORIGINS=http://localhost:8088 uvicorn homehub.server:app --port 8099
# 2) web build, served on :8088
cd app && flutter build web --release && (cd build/web && python3 -m http.server 8088)
# 3) scripts (needs node + `npm i playwright-core`, uses the system Chrome)
node tool/screenshots/shoot.js            # -> /workspace/screenshots/*.png
SCHEME=dark ONLY_DARK=1 node tool/screenshots/shoot.js
node tool/screenshots/live.js             # curl a command, check the app updates via /ws
```

The scripts turn on Flutter's semantics tree and click by accessible name. Map taps use the
canvas box plus the map's image size (600 px in demo mode).
