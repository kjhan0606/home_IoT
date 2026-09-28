import json
import time

import pytest
import responses

from homehub.cloud.auth import EnvTokenProvider, OAuth2RefreshTokenProvider
from homehub.cloud.errors import CloudNotConfiguredError

TOKEN_URL = "https://api.smartthings.com/v1/oauth/token"


def test_env_provider(monkeypatch):
    p = EnvTokenProvider("SMARTTHINGS_TOKEN", hint="get one")
    assert not p.available()
    with pytest.raises(CloudNotConfiguredError, match="get one"):
        p.get_token()
    monkeypatch.setenv("SMARTTHINGS_TOKEN", " abc ")
    assert p.available() and p.get_token() == "abc"


@responses.activate
def test_oauth_refresh_persists_rotated_tokens(tmp_path):
    store = tmp_path / "st_oauth.json"
    store.write_text(json.dumps({"access_token": "old", "refresh_token": "r1", "expires_at": time.time() - 1}))
    responses.post(TOKEN_URL, json={"access_token": "new", "refresh_token": "r2", "expires_in": 86399})
    p = OAuth2RefreshTokenProvider(TOKEN_URL, "cid", "secret", store)
    assert p.available()
    assert p.get_token() == "new"
    body = responses.calls[0].request.body
    assert "grant_type=refresh_token" in body and "refresh_token=r1" in body
    assert responses.calls[0].request.headers["Authorization"].startswith("Basic ")
    assert json.loads(store.read_text())["refresh_token"] == "r2"
    assert p.get_token() == "new" and len(responses.calls) == 1      # cached until expiry


@responses.activate
def test_oauth_code_exchange(tmp_path):
    responses.post(TOKEN_URL, json={"access_token": "a", "refresh_token": "r", "expires_in": 100})
    p = OAuth2RefreshTokenProvider(TOKEN_URL, "cid", "secret", tmp_path / "t.json")
    assert not p.available()
    p.exchange_authorization_code("code123", "https://hub.example/cb")
    assert "grant_type=authorization_code" in responses.calls[0].request.body
    assert p.available()
