"""Token providers for cloud adapters.

Adapters never read credentials directly; they ask a ``TokenProvider``. Today
both integrations use a Personal Access Token from an env var
(``EnvTokenProvider``). The OAuth2 authorization-code flow (needed for a
multi-user / App-Store build, and because new SmartThings PATs expire after
24 h) plugs in by passing an ``OAuth2RefreshTokenProvider`` instead — the
adapter code does not change. See docs/cloud-integrations.md.
"""
from __future__ import annotations

import json
import os
import threading
import time
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any

from .errors import CloudAuthError, CloudNotConfiguredError


class TokenProvider(ABC):
    @abstractmethod
    def available(self) -> bool:
        """True if credentials are configured (adapter is enabled)."""

    @abstractmethod
    def get_token(self) -> str:
        """Return a currently valid bearer token or raise CloudNotConfiguredError."""

    def invalidate(self) -> None:
        """Called after a 401 so refreshing providers can renew. No-op for PATs."""
        return None


class EnvTokenProvider(TokenProvider):
    """Personal Access Token read from an env var on every call (so the hub
    picks up a rotated token without code changes; restart not required)."""

    def __init__(self, env_var: str, hint: str = "") -> None:
        self.env_var = env_var
        self.hint = hint

    def available(self) -> bool:
        return bool(os.environ.get(self.env_var, "").strip())

    def get_token(self) -> str:
        tok = os.environ.get(self.env_var, "").strip()
        if not tok:
            raise CloudNotConfiguredError(
                f"{self.env_var} is not set. {self.hint}".strip()
            )
        return tok


class OAuth2RefreshTokenProvider(TokenProvider):
    """OAuth2 access/refresh-token provider (authorization-code grant).

    Holds ``{"access_token", "refresh_token", "expires_at"}`` in a JSON file
    under the hub's git-ignored token dir and refreshes the access token when it
    is within ``skew`` seconds of expiry or after a 401. Refresh tokens are
    single-use for SmartThings, so the new pair is persisted immediately.

    TODO(oauth): not wired into the registry yet. Remaining work:
      1. a hub route (e.g. GET /oauth/smartthings/start + /callback) that
         redirects to the vendor authorize URL with a CSRF ``state`` and calls
         ``exchange_authorization_code`` on the callback;
      2. choose this provider in ``adapters/registry.py`` when
         SMARTTHINGS_CLIENT_ID / SMARTTHINGS_CLIENT_SECRET are set;
      3. per-user token storage once the multi-tenant cloud relay exists.
    """

    def __init__(
        self,
        token_url: str,
        client_id: str,
        client_secret: str,
        store_path: Path,
        skew: int = 300,
        session: Any = None,
    ) -> None:
        self.token_url = token_url
        self.client_id = client_id
        self.client_secret = client_secret
        self.store_path = Path(store_path)
        self.skew = skew
        self._session = session
        self._lock = threading.Lock()

    # -- storage -----------------------------------------------------------
    def _load(self) -> dict[str, Any]:
        try:
            return json.loads(self.store_path.read_text())
        except Exception:
            return {}

    def _save(self, tok: dict[str, Any]) -> None:
        self.store_path.parent.mkdir(parents=True, exist_ok=True)
        self.store_path.write_text(json.dumps(tok))
        try:
            os.chmod(self.store_path, 0o600)
        except OSError:
            pass

    def save_token_response(self, resp: dict[str, Any]) -> None:
        self._save(
            {
                "access_token": resp["access_token"],
                "refresh_token": resp.get("refresh_token"),
                "expires_at": time.time() + float(resp.get("expires_in", 0)),
            }
        )

    # -- TokenProvider -----------------------------------------------------
    def available(self) -> bool:
        return bool(self._load().get("refresh_token") or self._load().get("access_token"))

    def get_token(self) -> str:
        with self._lock:
            tok = self._load()
            if not tok:
                raise CloudNotConfiguredError(
                    "OAuth not linked yet: complete the authorization-code flow first"
                )
            if tok.get("expires_at", 0) - self.skew <= time.time():
                tok = self._refresh(tok)
            return tok["access_token"]

    def invalidate(self) -> None:
        with self._lock:
            tok = self._load()
            if tok:
                tok["expires_at"] = 0
                self._save(tok)

    def _refresh(self, tok: dict[str, Any]) -> dict[str, Any]:
        if not tok.get("refresh_token"):
            raise CloudAuthError("access token expired and no refresh token stored")
        resp = self._post(
            {
                "grant_type": "refresh_token",
                "refresh_token": tok["refresh_token"],
                "client_id": self.client_id,
            }
        )
        self.save_token_response(resp)
        return self._load()

    def exchange_authorization_code(self, code: str, redirect_uri: str) -> None:
        """Step 5 of the flow: trade the ?code= from the redirect for tokens."""
        resp = self._post(
            {
                "grant_type": "authorization_code",
                "code": code,
                "client_id": self.client_id,
                "redirect_uri": redirect_uri,
            }
        )
        self.save_token_response(resp)

    def _post(self, data: dict[str, str]) -> dict[str, Any]:
        import requests

        http = self._session or requests
        r = http.post(
            self.token_url,
            data=data,
            auth=(self.client_id, self.client_secret),
            headers={"Accept": "application/json"},
            timeout=15,
        )
        if r.status_code != 200:
            raise CloudAuthError(f"token endpoint returned {r.status_code}: {r.text[:200]}")
        return r.json()
