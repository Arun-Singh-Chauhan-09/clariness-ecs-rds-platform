"""Least-privilege database role for the API.

The API stops using the master user. It connects as `referrals_app`, which can
only read and write rows: no DELETE, no DDL, no access to other schemas.
Migrations keep running as the master user.

- On RDS, the role gets `rds_iam`, so it logs in with short-lived IAM tokens
  (no password at all).
- Locally/CI, APP_DB_PASSWORD (if set when migrating) gives it a password.

No schema change: safe to run while the previous release is serving.

Revision ID: 0003
Revises: 0002
Create Date: 2026-11-17
"""
import os

from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None

ROLE = "referrals_app"
TABLES = ("studies", "referrals")


def upgrade() -> None:
    op.execute(
        f"""
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{ROLE}') THEN
            CREATE ROLE {ROLE} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
          END IF;
          IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'rds_iam') THEN
            GRANT rds_iam TO {ROLE};
          END IF;
          EXECUTE format('GRANT CONNECT ON DATABASE %I TO {ROLE}', current_database());
        END
        $$;
        """
    )
    op.execute(f"REVOKE CREATE ON SCHEMA public FROM {ROLE}")
    op.execute(f"GRANT USAGE ON SCHEMA public TO {ROLE}")
    op.execute(f"GRANT SELECT, INSERT, UPDATE ON {', '.join(TABLES)} TO {ROLE}")
    op.execute(f"GRANT SELECT ON alembic_version TO {ROLE}")
    op.execute(f"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {ROLE}")
    # Tables created by later migrations get the same row-level rights.
    op.execute(f"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE ON TABLES TO {ROLE}")
    op.execute(f"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO {ROLE}")

    password = os.getenv("APP_DB_PASSWORD")
    if password:  # local and CI only; on RDS the role uses IAM tokens
        # ALTER ROLE cannot take bind parameters, so quote the literal safely.
        quoted = "'" + password.replace("'", "''") + "'"
        op.execute(f"ALTER ROLE {ROLE} PASSWORD {quoted}")


def downgrade() -> None:
    # The role itself is cluster-wide and harmless without grants, so it is kept.
    op.execute(f"ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM {ROLE}")
    op.execute(f"ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM {ROLE}")
    op.execute(f"REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM {ROLE}")
    op.execute(f"REVOKE ALL ON {', '.join(TABLES)}, alembic_version FROM {ROLE}")
    op.execute(f"REVOKE USAGE ON SCHEMA public FROM {ROLE}")
