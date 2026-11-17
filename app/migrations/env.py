"""Alembic environment: reuses the application's connection settings."""

from logging.config import fileConfig

from alembic import context
from sqlalchemy import create_engine, pool

from referrals.db import database_url

# Log "Running upgrade 0001 -> 0002" etc. (logger config in alembic.ini).
if context.config.config_file_name is not None:
    fileConfig(context.config.config_file_name, disable_existing_loggers=False)

# Fail fast instead of queueing behind a long-running transaction: a migration
# that waits on a lock blocks every query queued behind it.
LOCK_TIMEOUT = "5s"
STATEMENT_TIMEOUT = "60s"


def run_migrations_offline() -> None:
    context.configure(url=str(database_url()), literal_binds=True, target_metadata=None)
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    engine = create_engine(database_url(), poolclass=pool.NullPool)
    with engine.connect() as connection:
        if connection.dialect.name == "postgresql":
            connection.exec_driver_sql(f"SET lock_timeout = '{LOCK_TIMEOUT}'")
            connection.exec_driver_sql(f"SET statement_timeout = '{STATEMENT_TIMEOUT}'")
            # SQLAlchemy 2.x opened a transaction for the SETs above. Commit it
            # (session-level settings survive the commit). Without this,
            # Alembic joins that outer transaction instead of owning it, and
            # everything is rolled back when the connection closes: the
            # migration "succeeds" with exit code 0 but changes nothing.
            connection.commit()
        context.configure(connection=connection, target_metadata=None)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
