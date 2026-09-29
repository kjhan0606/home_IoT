"""AutomationService: stores rules, keeps the run log, runs the engine on a timer.

Always-on operation: the hub process runs ``run_forever`` (started from the FastAPI lifespan). Every
``tick`` it (optionally) re-syncs cloud devices, evaluates the rules against the device changes since
the last tick and executes the resulting canonical commands through ``DeviceManager.execute`` -- the
same path the API uses, so every adapter works.
"""
from __future__ import annotations

import asyncio
import json
import logging
import threading
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from .. import config
from ..models import Device
from . import away as away_mod, engine, rules as rules_mod

log = logging.getLogger("homehub.automation")

MAX_LOG = 200
MAX_RULES = 100
AWAY_RETRY_SECONDS = 300      # a failing away-mode command is retried at most this often


def _now() -> datetime:
    tz = None
    if config.TIMEZONE:
        from zoneinfo import ZoneInfo

        tz = ZoneInfo(config.TIMEZONE)
    return datetime.now(tz)


class AutomationService:
    def __init__(self, manager: Any, path: Path | None = None, clock: Callable[[], datetime] = _now) -> None:
        self.manager = manager
        self.path = path
        self.clock = clock
        self._lock = threading.RLock()
        self._rules: list[dict[str, Any]] = []
        self._log: list[dict[str, Any]] = []
        self._last_fired: dict[str, str] = {}
        self._events: list[str] = []
        self._away: dict[str, Any] | None = None       # the one 휴가/장기 외출 plan (docs/home-automation.md)
        self._away_done = False
        self._away_on: set[str] = set()                # lights the plan turned on (so we only undo our own)
        self._away_failed: dict[str, datetime] = {}
        self._prev: dict[str, Device] | None = None
        self.on_fire: Callable[[dict[str, Any]], None] | None = None
        self._load()

    # ------------------------------------------------------------ storage --
    def _file(self) -> Path:
        return self.path or (config.DATA_DIR / "automation.json")

    def _load(self) -> None:
        try:
            d = json.loads(self._file().read_text())
        except Exception:
            return
        for r in d.get("rules", []):
            try:
                self._rules.append(rules_mod.normalize_rule(r))
            except ValueError:
                log.warning("dropping invalid stored rule %r", r.get("id"))
        self._log = list(d.get("log", []))[-MAX_LOG:]
        self._last_fired = dict(d.get("lastFired", {}))
        try:
            self._away = away_mod.normalize_plan(d["away"]) if d.get("away") else None
        except ValueError:
            log.warning("dropping invalid stored away plan")
        self._away_done = bool(d.get("awayDone", False))
        self._away_on = set(d.get("awayOn", []))

    def _save(self) -> None:
        try:
            config.ensure_dirs()
            self._file().write_text(json.dumps(
                {"rules": self._rules, "log": self._log[-MAX_LOG:], "lastFired": self._last_fired,
                 "away": self._away, "awayDone": self._away_done, "awayOn": sorted(self._away_on)},
                ensure_ascii=False, indent=2))
        except Exception:
            log.exception("could not save automation state")

    # -------------------------------------------------------------- rules --
    def list_rules(self) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(r) for r in self._rules]

    def get_rule(self, rule_id: str) -> dict[str, Any] | None:
        with self._lock:
            return next((dict(r) for r in self._rules if r["id"] == rule_id), None)

    def upsert(self, body: dict[str, Any], rule_id: str | None = None) -> dict[str, Any]:
        with self._lock:
            existing = next((r for r in self._rules if r["id"] == rule_id), None) if rule_id else None
            if rule_id and existing is None:
                raise KeyError(rule_id)
            if existing is None and len(self._rules) >= MAX_RULES:
                raise ValueError(f"at most {MAX_RULES} rules")
            rule = rules_mod.normalize_rule(body, rule_id)
            self._mark_due_as_done(rule)
            if existing is None:
                self._rules.append(rule)
            else:
                self._rules[self._rules.index(existing)] = rule
            self._save()
            return dict(rule)

    def set_enabled(self, rule_id: str, enabled: bool) -> dict[str, Any]:
        with self._lock:
            r = next((r for r in self._rules if r["id"] == rule_id), None)
            if r is None:
                raise KeyError(rule_id)
            r["enabled"] = enabled
            if enabled:
                self._mark_due_as_done(r)
            self._save()
            return dict(r)

    def delete(self, rule_id: str) -> None:
        with self._lock:
            n = len(self._rules)
            self._rules = [r for r in self._rules if r["id"] != rule_id]
            if len(self._rules) == n:
                raise KeyError(rule_id)
            self._last_fired.pop(rule_id, None)
            self._save()

    def _mark_due_as_done(self, rule: dict[str, Any]) -> None:
        """A time rule created/enabled *after* its time today must not fire retroactively."""
        key = engine.time_key(rule, self.clock())
        if key:
            self._last_fired[rule["id"]] = key

    # ------------------------------------------------- away (휴가) mode -----
    def get_away(self) -> dict[str, Any]:
        """Plan (or None), its status now, and the schedule of the current/next evening window."""
        now = self.clock()
        with self._lock:
            plan = dict(self._away) if self._away else None
            done = self._away_done
        if plan is None:
            return {"plan": None, "status": None, "schedule": []}
        st = away_mod.describe(plan, now)
        if done and st["state"] != "finished":
            st["state"] = "stopped"
        return {"plan": plan, "status": st, "schedule": self.away_schedule(plan, now)}

    def away_schedule(self, plan: dict[str, Any], now: datetime) -> list[dict[str, Any]]:
        """Per light: the on-intervals ("HH:MM") of the window that is running or starts next."""
        from datetime import timedelta

        now = now.replace(tzinfo=None)
        first, last = away_mod._dates(plan)
        wstart = away_mod.parse_hhmm(plan["windowStart"])
        day = now.date() if now >= away_mod._at(now.date(), wstart) else now.date() - timedelta(days=1)
        day = min(max(day, first), last)
        out = []
        for d in away_mod.chosen_lights(plan, self.snapshot().values()):
            t = away_mod.Target(d.id, d.name, d.meta.get("room"))
            iv = away_mod.light_intervals(plan, day, t)
            out.append({"deviceId": d.id, "name": d.name, "room": d.meta.get("room"), "date": day.isoformat(),
                        "intervals": [[a.strftime("%H:%M"), b.strftime("%H:%M")] for a, b in iv]})
        return out

    def set_away(self, body: dict[str, Any]) -> dict[str, Any]:
        plan = away_mod.normalize_plan(body)
        with self._lock:
            self._away, self._away_done, self._away_on = plan, False, set()
            self._away_failed.clear()
            self._save()
        return self.get_away()

    def stop_away(self, delete: bool = True) -> list[dict[str, Any]]:
        """Ends the mode (e.g. on return): lights the plan turned on are switched off again."""
        entries = self._away_finish("휴가 모드 종료", self.clock())
        with self._lock:
            if delete:
                self._away, self._away_done = None, False
            else:
                self._away_done = True
            self._away_on.clear()
            self._save()
        return entries

    def _away_finish(self, reason: str, now: datetime) -> list[dict[str, Any]]:
        with self._lock:
            plan, ons = self._away, sorted(self._away_on)
        if plan is None or not ons:
            return []
        cur = self.snapshot()
        wants = [away_mod.Want(i, cur[i].name, "power", "turnOff", reason) for i in ons if i in cur]
        return self._away_run(wants, cur, now, reason)

    def _away_step(self, w: away_mod.Want, cur: dict[str, Device]) -> engine.Step | None:
        d = cur.get(w.device_id)
        # SAFETY: the away mode may only ever switch lights on/off and open/close curtains.
        if d is None or (w.capability, w.action) not in (("power", "turnOn"), ("power", "turnOff"),
                                                         ("curtain", "open"), ("curtain", "close")):
            return None
        if w.capability == "power" and not away_mod.is_light(d):
            return None
        if w.capability == "curtain" and not away_mod.is_curtain(d):
            return None
        inst = d.capabilities.get(w.capability)
        if inst is None or w.action not in inst.actions:
            return None
        return engine.Step(d.id, d.name, w.capability, w.action, {}, engine._already(d, w.capability, w.action, {}))

    def _away_run(self, wants: list[away_mod.Want], cur: dict[str, Device], now: datetime,
                  reason: str) -> list[dict[str, Any]]:
        from datetime import timedelta

        steps = []
        for w in wants:
            s = self._away_step(w, cur)
            if s is None or s.skip:
                if s is not None and s.skip and w.capability == "power" and w.action == "turnOn":
                    self._away_on.add(w.device_id)
                continue
            failed = self._away_failed.get(w.device_id)
            if failed and now.replace(tzinfo=None) - failed < timedelta(seconds=AWAY_RETRY_SECONDS):
                continue
            steps.append(s)
        if not steps:
            return []
        fire = engine.Fire("away", "휴가 모드", reason, None, steps)
        entry = self._run(fire, now)
        with self._lock:
            for r in entry["steps"]:
                if r["ok"]:
                    self._away_failed.pop(r["deviceId"], None)
                    if r["capability"] == "power":
                        (self._away_on.add if r["action"] == "turnOn" else self._away_on.discard)(r["deviceId"])
                else:
                    self._away_failed[r["deviceId"]] = now.replace(tzinfo=None)
            self._log.append(entry)
            self._save()
        if self.on_fire:
            try:
                self.on_fire(entry)
            except Exception:
                log.exception("on_fire failed")
        return [entry]

    def _away_tick(self, now: datetime, events: list[str]) -> list[dict[str, Any]]:
        with self._lock:
            plan, done = self._away, self._away_done
        if plan is None or done:
            return []
        if "arriving" in events and plan.get("endOnArriving", True):
            return self.stop_away(delete=False)
        st = away_mod.status(plan, now)
        if st["state"] == "finished":
            out = self._away_finish("휴가 모드 끝남", now)
            with self._lock:
                self._away_done = True
                self._away_on.clear()
                self._save()
            return out
        wants = away_mod.wants(plan, now, self.snapshot().values())
        return self._away_run(wants, self.snapshot(), now, wants[0].reason if wants else "")

    # --------------------------------------------------------------- log ---
    def run_log(self, limit: int = 50) -> list[dict[str, Any]]:
        with self._lock:
            return list(reversed(self._log[-limit:]))

    def clear_log(self) -> None:
        with self._lock:
            self._log.clear()
            self._save()

    def emit_event(self, name: str) -> None:
        """Queue a named event ('leaving', 'arriving', 'wake', 'alarm', ...) for the next tick."""
        if not name or len(name) > 40:
            raise ValueError("bad event name")
        with self._lock:
            self._events.append(name)

    # -------------------------------------------------------------- tick ---
    def snapshot(self) -> dict[str, Device]:
        return {d.id: Device.from_dict(d.to_dict()) for d in self.manager.list_devices()}

    def tick(self, now: datetime | None = None, refresh: bool = False) -> list[dict[str, Any]]:
        """One evaluation pass. Returns the log entries produced."""
        now = now or self.clock()
        with self._lock:
            active = [r for r in self._rules if r["enabled"]]
            events, self._events = self._events, []
        away_on = self._away is not None and not self._away_done
        if not active and not events and not away_on:
            self._prev = None
            return []
        if refresh and (away_on or any(r["trigger"]["type"] in ("allLightsOff", "deviceState") for r in active)):
            try:
                self.manager.scan(lan=False, cloud=True)
            except Exception:
                log.exception("device refresh failed")
        cur = self.snapshot()
        with self._lock:
            fires = engine.evaluate(active, self._prev, cur, now, events, self._last_fired)
            self._prev = cur
            for f in fires:
                if f.key:
                    self._last_fired[f.rule_id] = f.key
        entries = [self._run(f, now) for f in fires]
        if entries:
            with self._lock:
                self._log.extend(entries)
                self._save()
            for e in entries:
                if self.on_fire:
                    try:
                        self.on_fire(e)
                    except Exception:
                        log.exception("on_fire failed")
        entries += self._away_tick(now, events)
        return entries

    def _run(self, fire: engine.Fire, now: datetime) -> dict[str, Any]:
        results = []
        for s in fire.steps:
            r: dict[str, Any] = {**s.to_dict(), "ok": True}
            if s.skip:
                r["ok"] = True
            else:
                try:
                    self.manager.execute(s.device_id, s.capability, s.action, s.params)
                except Exception as e:  # noqa: BLE001 - one failing device must not stop the rest
                    r["ok"], r["error"] = False, str(e)
            results.append(r)
        if not fire.steps:
            status = "no-targets"
        elif all(r.get("skip") for r in results):
            status = "skipped"
        elif any(not r["ok"] for r in results):
            status = "error" if not any(r["ok"] and not r.get("skip") for r in results) else "partial"
        else:
            status = "ok"
        return {"time": now.isoformat(timespec="seconds"), "ruleId": fire.rule_id, "ruleName": fire.rule_name,
                "reason": fire.reason, "status": status, "steps": results}

    async def run_forever(self, interval: float | None = None, refresh_every: float | None = None) -> None:
        interval = interval or config.AUTOMATION_TICK_SECONDS
        refresh_every = refresh_every or config.AUTOMATION_REFRESH_SECONDS
        since_refresh = refresh_every            # refresh on the first pass
        while True:
            try:
                refresh = since_refresh >= refresh_every
                await asyncio.to_thread(self.tick, None, refresh)
                since_refresh = 0 if refresh else since_refresh + interval
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("automation tick failed")
            await asyncio.sleep(interval)
