"""Tiny secret store: one JSON file per integration under the hub's token dir.

* directory created 0700, files written atomically with mode 0600;
* values are never logged by this module; ``describe()`` gives a redacted view.
The token dir lives in ``hub/data/`` which is git-ignored.
"""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any

from . import config


def _dir() -> Path:
    d = Path(config.TOKEN_DIR)
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def path_for(name: str) -> Path:
    if not name.replace("_", "").isalnum():
        raise ValueError("invalid secret name")
    return _dir() / f"{name}.json"


def save(name: str, data: dict[str, Any]) -> Path:
    target = path_for(name)
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=f".{name}.", suffix=".tmp")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.chmod(target, 0o600)
    return target


def load(name: str) -> dict[str, Any] | None:
    try:
        return json.loads(path_for(name).read_text())
    except (OSError, ValueError):
        return None


def delete(name: str) -> bool:
    try:
        path_for(name).unlink()
        return True
    except FileNotFoundError:
        return False


def secure_touch(path: Path) -> Path:
    """Create (if missing) a 0600 file, e.g. for a library-managed cache."""
    _dir()
    fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o600)
    os.close(fd)
    os.chmod(path, 0o600)
    return path
