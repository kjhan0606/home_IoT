"""Brand-neutral automation rules (trigger -> actions) for the hub.

* ``rules.py``   rule schema + validation (the same JSON the app's local engine uses)
* ``engine.py``  pure evaluation: (rules, previous/current device snapshot, time, events) -> fires
* ``service.py`` persistence, run log, background tick loop, command execution

Rules only refer to canonical capabilities (``curtain``, ``power``, ...) and device
*kinds*, never to a brand, so they work for every adapter. See docs/home-automation.md.
"""
