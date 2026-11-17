import os

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import ProgrammingError

STUDY = {"code": "SEC-2026-001", "display_name": "Security test study", "phase": "I"}


@pytest.mark.parametrize(
    "method, path",
    [("get", "/studies"), ("post", "/studies"), ("get", "/studies/1"), ("patch", "/referrals/1")],
)
def test_business_endpoints_require_api_key(anon_client, method, path):
    body = STUDY if method in ("post", "patch") else None
    resp = anon_client.request(method.upper(), path, json=body)
    assert resp.status_code == 401
    assert resp.headers["www-authenticate"] == "ApiKey"


def test_wrong_api_key_rejected(anon_client):
    resp = anon_client.get("/studies", headers={"X-API-Key": "wrong-key-0123456789"})
    assert resp.status_code == 401


def test_health_and_metrics_do_not_need_a_key(anon_client):
    assert anon_client.get("/healthz").status_code == 200
    assert anon_client.get("/readyz").status_code == 200
    assert anon_client.get("/metrics").status_code == 200


def test_security_headers(client):
    resp = client.get("/studies")
    assert resp.headers["x-content-type-options"] == "nosniff"
    assert resp.headers["cache-control"] == "no-store"
    assert "strict-transport-security" not in resp.headers
    https = client.get("/studies", headers={"X-Forwarded-Proto": "https"})
    assert https.headers["strict-transport-security"].startswith("max-age=")


def test_api_docs_disabled_by_default(client):
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404


def test_short_api_keys_are_refused():
    from referrals.auth import load_key_digests

    with pytest.raises(ValueError):
        load_key_digests("short")
    assert load_key_digests("") == []


def test_iam_auth_url_has_no_password(monkeypatch):
    from referrals.db import database_url

    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("DB_IAM_AUTH", "true")
    monkeypatch.setenv("DB_USER", "referrals_app")
    monkeypatch.setenv("DB_HOST", "db.example.internal")
    monkeypatch.setenv("DB_NAME", "referrals")
    url = database_url()
    assert url.password is None
    assert url.query["sslmode"] == "require"


@pytest.mark.skipif(not os.getenv("APP_DB_PASSWORD"), reason="APP_DB_PASSWORD not set")
def test_app_role_is_least_privileged():
    """referrals_app can read and write rows, but cannot delete or change the schema."""
    url = make_url(os.environ["DATABASE_URL"]).set(
        username="referrals_app", password=os.environ["APP_DB_PASSWORD"]
    )
    engine = create_engine(url)
    try:
        with engine.begin() as conn:
            conn.execute(
                text(
                    "INSERT INTO studies (code, title, display_name, phase, created_at) "
                    "VALUES ('PRV-2026-001', 't', 't', 'I', now())"
                )
            )
            assert conn.execute(text("SELECT count(*) FROM studies")).scalar() >= 1
        for statement in (
            "DELETE FROM studies",
            "DROP TABLE referrals",
            "CREATE TABLE evil (id int)",
            "ALTER TABLE studies ADD COLUMN x int",
        ):
            with pytest.raises(ProgrammingError), engine.begin() as conn:
                conn.execute(text(statement))
    finally:
        engine.dispose()
