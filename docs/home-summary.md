# 집 전체 요약 (Home Summary)

One screen and one line of text that say what is going on in the whole home, across brands:

> 세탁 끝남, 냉장고 문 열림 12분, 로봇청소기 충전 필요, 현관 카메라 방문자 2명

## Where it lives

| Piece | File |
|---|---|
| Summary engine (pure, no I/O) | `app/lib/summary/home_summary.dart` |
| Local notifications | `app/lib/summary/summary_notifier.dart` |
| Home-screen top card | `app/lib/screens/home_summary_card.dart` |
| Full screen | `app/lib/screens/home_summary_screen.dart` |
| Tests | `app/test/summary_test.dart`, `app/test/home_ui_test.dart` |

The engine reads only **canonical capabilities** (`washer`, `dryer`, `refrigeration`, `vacuum`,
`consumables`, `lock`, `curtain`, `power` on lights, `sensor`) from `Device`s. It never looks at a brand,
so it behaves the same in direct-cloud mode and hub mode (both hand the app the same `Device` model).
A category the home does not have simply produces no card.

## Levels (prioritized cards)

1. **확인 필요 (needs attention)** – laundry finished (last 6 h), fridge door open (with minutes), fridge too
   warm (>= 10 C), robot needs charging (battery <= 20 % and not on the dock), robot error, consumable
   <= 10 %, door lock unlocked, camera visitors/motion, offline devices, 휴가 모드 problems.
2. **진행 중 (in progress)** – laundry running (remaining minutes), robot cleaning/returning/paused, TV on,
   lights on, **휴가 모드 켜짐, N일째**.
3. **이상 없음 (all good)** – fridge OK, robot docked, lock locked, lights all off, curtains state,
   camera quiet.

Inside a level items are ordered by a fixed rank (door lock first, then laundry, fridge, robot, camera...).
`HomeSummary.oneLine()` joins the first four titles of the highest non-empty level (`외 N건` for the rest);
with nothing to report it says `집 안 모두 정상입니다`.

### Durations the vendors do not give us

Samsung/LG do not timestamp "door opened" or "cycle ended while you were watching". `SummaryTracker`
(fed by every device sync in `HubState`) remembers when it first saw a condition, so "냉장고 문 열림 12분"
is measured from the first sync that saw the door open. Consequence: right after the app starts the
duration is unknown (`냉장고 문 열림`, no minutes) until it has observed the door for a while, unless the
backend provides `doorOpenSince` / `completionTime` (the engine uses those when present).

### Camera contract (works with the CCTV branch)

Camera items appear **only if** a device has `kind == "camera"` or a `videoStream` capability. They read
the `sensor` capability: `readings.visitorCount` (people seen at the door recently) and `readings.motion`
(1 = motion now). A camera without those readings shows "이상 없음". No camera in the home = no camera
item at all (tested). The `feature/cctv` branch has to fill in those two readings (e.g. from ONVIF
events / a motion detector); until it does, the demo hub fakes them on `demo:cam-entrance`.

## Notifications (local, while the app runs)

`SummaryNotifier` listens to the device list and raises a `flutter_local_notifications` notification when a
**new** attention item appears. Title = the new item (or "집 알림 N건"), body = the one-line summary of
everything that needs attention. Rules:

* the first device list after connecting only records state (no flood on startup);
* one item notifies once; it can notify again only after it went away and came back;
* the `notifySummary` preference (default on, `SettingsStore`) switches it off and the permission prompt is only requested when it is on. **There is no switch for it in the settings screen yet** (remaining work).

**Limit – read this before promising anything:** these notifications are raised *by the app itself*, so
they only appear while the app process is alive (foreground, or shortly after being backgrounded before
iOS/Android suspend it). "Your washer finished" while the phone is in a pocket and the app is closed needs a
server that watches the devices and sends APNs/FCM push. That is the **premium relay** (Pro tier and up
in `premium-server.md`); it is not built here. With a hub the hub could send the push, but the hub has no
APNs/FCM credentials either, so it is the same relay problem.

Platform setup done in this branch: Android `POST_NOTIFICATIONS` permission and core-library desugaring
(required by the plugin), iOS `UNUserNotificationCenter` delegate. **None of this has been run on a phone.**

## Tier suggestion (docs only, nothing enforced)

| | Free | Pro | Max | Mmax |
|---|---|---|---|---|
| Home Summary screen + card | yes | yes | yes | yes |
| Local notifications (app open) | yes | yes | yes | yes |
| Push while the app is closed | - | yes (relay) | yes | yes |

Reasoning: the summary costs us nothing to run (it is computed on the phone), so gating it would only
annoy; the paid value is the relay that makes it work with the app closed, which matches the existing
"푸시 알림: Pro 이상" row.
