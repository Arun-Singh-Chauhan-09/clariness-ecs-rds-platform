"""Tests run against a real PostgreSQL (docker compose locally, a service container in CI).

Set DATABASE_URL, e.g.:
  postgresql+psycopg://referrals:referrals@localhost:5432/referrals_test
"""

import os
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text

if not os.getenv("DATABASE_URL"):
    # No database: collect nothing instead of failing on import of referrals.db.
    print("DATABASE_URL not set; start Postgres with `make up` (skipping DB tests)")
    collect_ignore_glob = ["test_*.py"]

APP_DIR = Path(__file__).resolve().parents[1]


def alembic_config() -> Config:
    cfg = Config(str(APP_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(APP_DIR / "migrations"))
    return cfg


@pytest.fixture(scope="session", autouse=True)
def migrated_db():
    cfg = alembic_config()
    command.downgrade(cfg, "base")
    command.upgrade(cfg, "head")
    yield


@pytest.fixture(autouse=True)
def clean_tables():
    from referrals.db import engine

    with engine.begin() as conn:
        conn.execute(text("TRUNCATE referrals, studies RESTART IDENTITY CASCADE"))
    yield


@pytest.fixture
def client():
    from fastapi.testclient import TestClient

    from referrals.main import app

    with TestClient(app) as c:
        yield c
