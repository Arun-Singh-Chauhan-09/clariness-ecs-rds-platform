"""Database engine and connection settings.

In AWS the connection details arrive as separate environment variables:
DB_HOST/DB_NAME/DB_USER come from Terraform outputs, and DB_PASSWORD is
injected by ECS from the RDS-managed Secrets Manager secret. Locally,
DATABASE_URL is used instead.
"""

from __future__ import annotations

import os

from sqlalchemy import create_engine
from sqlalchemy.engine import URL, Engine


def database_url() -> str | URL:
    if url := os.getenv("DATABASE_URL"):
        return url

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
            "sslmode": os.getenv("DB_SSLMODE", "prefer"),
            "connect_timeout": os.getenv("DB_CONNECT_TIMEOUT", "5"),
            "application_name": os.getenv("APP_NAME", "referrals-api"),
        },
    )


def make_engine() -> Engine:
    return create_engine(
        database_url(),
        # One uvicorn worker per task: total connections = tasks x pool_size.
        # Keep (max tasks x pool_size) + migration task well below max_connections.
        pool_size=int(os.getenv("DB_POOL_SIZE", "5")),
        max_overflow=int(os.getenv("DB_MAX_OVERFLOW", "0")),
        pool_timeout=float(os.getenv("DB_POOL_TIMEOUT", "5")),
        # Detects connections killed by a Multi-AZ failover before using them.
        pool_pre_ping=True,
        pool_recycle=1800,
    )


engine = make_engine()
