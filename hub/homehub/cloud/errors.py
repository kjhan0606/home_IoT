"""Error types raised by cloud adapters.

They subclass the built-in exceptions the API layer already maps to HTTP codes:
  * ``RemoteControlDisabledError`` -> PermissionError -> 403
  * ``CloudNotConfiguredError``    -> handled explicitly -> 503
  * ``CloudAuthError`` / ``CloudAPIError`` -> RuntimeError -> 502
"""
from __future__ import annotations


class CloudNotConfiguredError(RuntimeError):
    """The integration has no credentials (e.g. token env var unset)."""


class CloudAuthError(RuntimeError):
    """Vendor rejected our credentials (401/403): token invalid or expired."""


class CloudAPIError(RuntimeError):
    """Any other non-2xx answer or transport failure from a vendor cloud."""

    def __init__(self, message: str, status: int | None = None, code: str | None = None):
        super().__init__(message)
        self.status = status
        self.code = code


class RemoteControlDisabledError(PermissionError):
    """Appliance refuses remote start until the user enables it on the device."""
