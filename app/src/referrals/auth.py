"""API-key authentication.

Clients send `X-API-Key: <key>`. Valid keys come from the API_KEYS environment
variable (comma-separated); on ECS it is injected from Secrets Manager.

- Only SHA-256 digests of the keys are kept in memory, and comparisons use
  hmac.compare_digest, so timing does not reveal how much of a key matched.
- Fail closed: with no keys configured, every protected request is rejected.
- The first 8 hex characters of the key's digest are a non-secret key id. It is
  logged with each request, which gives an access audit trail without ever
  logging the key itself.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os

from fastapi import Header, HTTPException, Request

log = logging.getLogger("referrals.auth")


def _digest(key: str) -> bytes:
    return hashlib.sha256(key.encode()).digest()


def load_key_digests(raw: str | None = None) -> list[bytes]:
    raw = os.getenv("API_KEYS", "") if raw is None else raw
    keys = [k.strip() for k in raw.split(",") if k.strip()]
    short = [k for k in keys if len(k) < 16]
    if short:
        raise ValueError("API keys must be at least 16 characters long")
    if not keys:
        log.warning("API_KEYS is empty: all protected endpoints will return 401")
    return [_digest(k) for k in keys]


_KEY_DIGESTS = load_key_digests()


def require_api_key(
    request: Request,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> None:
    if x_api_key:
        candidate = _digest(x_api_key)
        # Compare against every key (no early exit) to keep timing uniform.
        matched = False
        for digest in _KEY_DIGESTS:
            matched |= hmac.compare_digest(candidate, digest)
        if matched:
            request.state.key_id = candidate.hex()[:8]
            return
    raise HTTPException(
        status_code=401,
        detail="missing or invalid API key",
        headers={"WWW-Authenticate": "ApiKey"},
    )
