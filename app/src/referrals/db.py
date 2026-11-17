"""Database engine and connection settings.

Two ways to authenticate:

- AWS (API service): DB_IAM_AUTH=true. The app connects as the least-privileged
  role `referrals_app` with a short-lived IAM auth token (15 min) generated per
  new connection from the ECS task role. No database password exists for it.
- Password: migrations and DR verification connect as the master user with the
  password ECS injects from the RDS-managed secret; locally, DATABASE_URL.
"""

from __future__ import annotations

import functools
import os

from sqlalchemy import create_engine, event
from sqlalchemy.engine import URL, Engine


def iam_auth_enabled() -> bool:
    return os.getenv("DB_IAM_AUTH", "false") == "true"


def database_url() -> str | URL:
    if url := os.getenv("DATABASE_URL"):
        return url

    if iam_auth_enabled():
        password = None  # supplied per connection by the do_connect hook below
    else:
        # DRILL_DB_PASSWORD is only set by scripts/dr-restore-drill.sh, when the
        # verification task points at a temporary restored instance.
        password = os.getenv("DRILL_DB_PASSWORD") or os.environ["DB_PASSWORD"]

    return URL.create(
        "postgresql+psycopg",
        username=os.environ["DB_USER"],
        password=password,
        host=os.environ["DB_HOST"],
        port=int(os.getenv("DB_PORT", "5432")),
        database=os.environ["DB_NAME"],
        query={
            # IAM authentication requires TLS; RDS also enforces it (rds.force_ssl).
            "sslmode": os.getenv("DB_SSLMODE", "require" if iam_auth_enabled() else "prefer"),
            "connect_timeout": os.getenv("DB_CONNECT_TIMEOUT", "5"),
            "application_name": os.getenv("APP_NAME", "referrals-api"),
        },
    )


@functools.lru_cache(maxsize=1)
def _rds_client():
    import boto3  # imported lazily: only needed on AWS

    return boto3.client("rds", region_name=os.environ["AWS_REGION"])


def iam_auth_token() -> str:
    return _rds_client().generate_db_auth_token(
        DBHostname=os.environ["DB_HOST"],
        Port=int(os.getenv("DB_PORT", "5432")),
        DBUsername=os.environ["DB_USER"],
        Region=os.environ["AWS_REGION"],
    )


def make_engine(**overrides) -> Engine:
    kwargs = {
        # One uvicorn worker per task: total connections = tasks x pool_size.
        # Keep (max tasks x pool_size) + migration task well below max_connections.
        "pool_size": int(os.getenv("DB_POOL_SIZE", "5")),
        "max_overflow": int(os.getenv("DB_MAX_OVERFLOW", "0")),
        "pool_timeout": float(os.getenv("DB_POOL_TIMEOUT", "5")),
        # Detects connections killed by a Multi-AZ failover before using them.
        "pool_pre_ping": True,
        # Recycle before IAM tokens (15 min) matter and before idle timeouts.
        "pool_recycle": 600,
    }
    if "poolclass" in overrides:  # e.g. NullPool: no pool sizing arguments
        for key in ("pool_size", "max_overflow", "pool_timeout", "pool_recycle"):
            kwargs.pop(key)
    kwargs.update(overrides)
    engine = create_engine(database_url(), **kwargs)

    if iam_auth_enabled():

        @event.listens_for(engine, "do_connect")
        def _provide_token(dialect, conn_rec, cargs, cparams):
            cparams["password"] = iam_auth_token()

    return engine


engine = make_engine()
