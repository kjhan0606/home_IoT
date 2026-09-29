import os
import sys
import tempfile
from pathlib import Path

# Isolate hub state before homehub.config is imported.
os.environ["HOMEHUB_DATA"] = tempfile.mkdtemp(prefix="homehub-test-")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pytest  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch, tmp_path):
    monkeypatch.setattr("homehub.config.AUTOMATION_ENABLED", False)   # no background tick loop in tests
    for var in ("SMARTTHINGS_TOKEN", "LG_THINQ_TOKEN", "LG_THINQ_COUNTRY", "LG_THINQ_API_BASE",
                "LG_THINQ_CLIENT_ID", "SMARTTHINGS_API_BASE", "HOMEHUB_TOKEN"):
        monkeypatch.delenv(var, raising=False)
    from homehub import config
    monkeypatch.setattr(config, "DATA_DIR", tmp_path)
    monkeypatch.setattr(config, "TOKEN_DIR", tmp_path / "tokens")
    monkeypatch.setattr(config, "DEVICES_FILE", tmp_path / "devices.json")
    yield
