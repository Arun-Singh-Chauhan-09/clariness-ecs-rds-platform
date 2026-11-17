from alembic import command
from sqlalchemy import inspect

from .conftest import alembic_config


def test_migrations_round_trip():
    """Every migration can be applied, rolled back and re-applied."""
    from referrals.db import engine

    cfg = alembic_config()
    command.downgrade(cfg, "base")
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "0001")
    command.upgrade(cfg, "head")

    columns = {c["name"] for c in inspect(engine).get_columns("studies")}
    assert {"title", "display_name"} <= columns
