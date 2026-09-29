# IP cameras / CCTV (인터넷 CCTV)

Adds home IP cameras to the app **on the home Wi-Fi only**. Nothing here sends video outside the
house. Branch `feature/cctv` (local, not pushed).

> **Unverified: no real camera was tested.** Everything below is covered by unit tests with mocked
> ONVIF/HTTP answers, the demo cameras, and one real `ffmpeg` output check. See [Unverified](#unverified).

## What you get

- A **camera** device type built on two new brand-neutral capabilities (like every other device):
  - `videoStream` (uiHint `camera-view`): protocol, RTSP URL, profiles (resolutions), snapshot/MJPEG availability. Action `selectProfile`.
  - `ptz` (uiHint `ptz-pad`): pan/tilt/zoom. Actions `move`, `stop`, `gotoPreset`. Only shown if the camera has PTZ.
- App: a **camera grid** on the device list, a **camera screen** (live view, snapshot refresh, PTZ pad, presets, profile), and an
  **add camera** screen (auto-found ONVIF cameras, or a manual RTSP / MJPEG / JPEG address plus user and password).
- The UI has no brand code. It picks widgets from the capability list only. The SmartThings (`videoStream`, `imageCapture`)
  and Matter (Camera AV Stream Management 0x0551, AV Settings User Level 0x0552) mappings are in `hub/homehub/mappings.py`.

## Protocols

| Protocol | How it is added | Snapshot | Live view | PTZ |
|---|---|---|---|---|
| `onvif` | IP (auto-found by WS-Discovery, or typed) + user + password | ONVIF snapshot URI, else ffmpeg grab from RTSP (hub only) | RTSP URI from ONVIF profile | ONVIF PTZ service, presets |
| `rtsp` | `rtsp://host:554/path` (+ user/password) | ffmpeg grab (hub only) | RTSP | no |
| `http` | `http://host/video.mjpg` (MJPEG) or `http://host/snap.jpg` (single JPEG) | the JPEG / first MJPEG frame | MJPEG, or repeated snapshots | no |

Credentials are never put into the device the app or API sees: the RTSP URL shown in the API has no user/password.

## Two modes

### Direct mode (app talks to the camera itself, LAN)

- Dart code in `app/lib/camera/` and `app/lib/backend/direct/camera_provider.dart` (`DirectCameraProvider`, a `CloudProvider` with id `camera`).
- ONVIF client (SOAP with WS-Security PasswordDigest, camera clock offset handled), WS-Discovery over UDP multicast (`dart:io`), Basic/Digest HTTP auth,
  MJPEG frame splitter, TCP probe of the RTSP/HTTP port.
- Live view on iOS/Android: **RTSP through `media_kit`** (libmpv/FFmpeg, RTSP over TCP). If it fails the view falls back to MJPEG, then to periodic snapshots.
- Camera list and passwords: `flutter_secure_storage` (Keychain / Keystore), key `cameras_v1`. Works with **no cloud account** ("계정 없이 IP 카메라만 사용하기" on the first screen).
- No PTZ/preset/profile change is possible for `rtsp`/`http` cameras, only for ONVIF.

### Hub mode (the phone talks to the hub, the hub talks to the camera)

- `hub/homehub/camera/` (`onvif.py`, `media.py`, `store.py`) and `hub/homehub/adapters/camera.py` (`CameraAdapter`, id `camera`, hidden from `/integrations`).
- ONVIF WS-Discovery runs together with mDNS/SSDP in `/scan`. Hosts with an open port 554/8554 are probed and get the `camera` kind as a weak hint.
- Cameras are stored in `hub/data/cameras.json` (**mode 0600**, same mechanism as other secrets). API views hide the password (`hasPassword`).
- The phone never sees the camera password in hub mode. Live view is MJPEG relayed by the hub with `ffmpeg` (or snapshots); the RTSP URL is returned without credentials.

| Method | Path | Purpose |
|---|---|---|
| GET | `/cameras/discover` | ONVIF WS-Discovery now |
| GET | `/cameras` | configured cameras (no passwords) |
| POST | `/cameras` | `{protocol, name, address\|url, username, password}` |
| DELETE | `/cameras/{id}` | remove + delete stored password |
| GET | `/devices/{id}/snapshot.jpg` | one JPEG |
| GET | `/devices/{id}/stream.mjpeg?fps=5` | MJPEG (max 4 streams at once, fps 1..15) |
| GET | `/devices/{id}/stream` | info: RTSP URL (no credentials), snapshot/mjpeg URLs, `hlsUrl` (currently `null`), ffmpeg available |
| POST | `/devices/{id}/commands` | `ptz`: `move/stop/gotoPreset`, `videoStream`: `selectProfile` (the usual command endpoint) |

All need the hub token if `HOMEHUB_TOKEN` is set. A wrong **camera** password returns HTTP 403 (not 401) so it is not confused with a bad hub token.
PTZ `move` stops itself after `durationMs` (default 500 ms, max 5 s), so a lost connection cannot leave the camera spinning.

## Demo mode

- Hub: `HOMEHUB_FAKE_DEVICES=1` adds `demo:cam-living` (PTZ with 2 presets, the picture visibly shifts) and `demo:cam-door`. Pictures are drawn by Pillow.
- App direct mode: on the add-camera screen, "예시: 거실 / 현관" buttons add the same two cameras from bundled pictures (`app/assets/demo/`). No network is used.
- Screenshots: `node app/tool/screenshots/cameras.js` (see `app/tool/screenshots/README.md`).

## Security notes (please read)

1. **Never open camera ports (554, 80, 8000, 8554 ...) to the internet** (no port forwarding, no UPnP, no DMZ). Exposed cameras are found and hijacked within hours. This feature is LAN-only on purpose.
2. **Change the default password** on every camera before adding it. Turn off cloud/P2P features you do not use.
3. RTSP and ONVIF here are **not encrypted** (plain HTTP/RTSP on the LAN). Keep cameras on a trusted Wi-Fi (ideally a separate guest/IoT network).
4. **Privacy / PIPA (개인정보 보호법):** video that shows other people (guests, neighbours, delivery people, a public passage) is personal information.
   Recording or filming public areas, or other people's homes, can be illegal; signage and consent rules apply to fixed cameras.
   This app only *views*; it does not record. Do not add recording without legal review.
5. Passwords are kept in Keychain/Keystore (app) or a 0600 file (hub). They are not logged; URLs shown or logged are redacted.

## Remote viewing (outside the home): not built, premium idea

Out of scope for this branch. The proper design is a **relay** service (WebRTC with TURN/relay, or an outbound tunnel from the hub), never port forwarding.
It costs bandwidth, so it fits a paid tier. Needs: a stream-capable home agent (hub), signalling server, auth per camera, and a PIPA review.
HLS from the hub (`hlsUrl`) is not implemented yet either; it would be the input to such a relay.

### DRAFT: camera limits per tier (design assumption, not decided, not in the premium branch)

The premium doc (`docs/premium-server.md` on `docs/premium-server`) has 5 / 10 / 30 / unlimited registered devices. Suggested addition:

| | Free | Pro | Max | Mmax |
|---|---|---|---|---|
| Cameras (LAN live view, in the device limit) | up to 2 | up to 3 | up to 8 | up to 16 (fair use) |
| Remote viewing through relay | ✗ | ✗ | ✔ (1 stream at a time) | ✔ (3 at a time) |
| Camera snapshot push on motion | ✗ | ✗ | later | later |

Cameras count toward the device limit. Free enforces it in the app (soft limit), as with other devices.
The numbers are guesses: relay bandwidth cost has not been measured.

## Packaging notes

- `media_kit` + `media_kit_libs_video` bundle libmpv/FFmpeg. Check the **licence of the libs variant** (LGPL vs GPL builds) and App Store rules before shipping. iOS/Android native builds were **not** done here.
- iOS: `NSLocalNetworkUsageDescription` and `NSAllowsLocalNetworking` already exist. Multicast (WS-Discovery) on iOS may need Apple's *multicast networking entitlement*; if refused, discovery falls back to typing the camera IP.
- Android: cleartext is already enabled; WS-Discovery needs a multicast lock (`CHANGE_WIFI_MULTICAST_STATE` present).
- **Web build:** no RTSP, no sockets (so no auto-discovery, no ONVIF, no MJPEG streaming via `package:http`). On web only the hub mode works, with snapshots. Web builds compile (`flutter build web`).

## Unverified

- **No real camera** (ONVIF, RTSP, PTZ, snapshot URL, Digest/Basic on real firmware). Vendors differ; expect fixes.
- WS-Security digest was checked against the spec formula and mocked SOAP only; WS-Discovery multicast was never run against a camera.
- `ffmpeg` RTSP→JPEG and RTSP→MJPEG were only tested with a mocked subprocess. The MJPEG frame splitter was checked on real ffmpeg output.
- `media_kit` RTSP playback was not built or run (no Android SDK, no Mac). Only the analyzer and the web compile.
- SmartThings-listed cloud cameras were skipped (not trivial).

## Remaining work

Try with a real camera (ONVIF and plain RTSP) · build and test on a phone · HLS/WebRTC for hub live view and the relay · motion events / push · recording (needs legal review) ·
two-way audio · camera-count limits in the app · iOS multicast entitlement request.
