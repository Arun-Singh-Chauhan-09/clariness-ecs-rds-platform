"""EXPAND: add studies.display_name next to the legacy title column.

Step 1 of a zero-downtime rename (title -> display_name):
  release N   (this migration): add nullable column, backfill it.
              The app writes BOTH columns and reads display_name.
  release N+1 (migrations/pending/0003): drop title, once no running task
              still reads it.

Revision ID: 0002
Revises: 0001
Create Date: 2026-11-17
"""
import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

BATCH_SIZE = 5000


def upgrade() -> None:
    # Adding a nullable column without a default is a metadata-only change in
    # PostgreSQL: no table rewrite, only a brief lock.
    op.add_column("studies", sa.Column("display_name", sa.String(200), nullable=True))

    # Backfill in batches so no single statement holds row locks for long.
    conn = op.get_bind()
    while True:
        updated = conn.execute(
            sa.text(
                "UPDATE studies SET display_name = title "
                "WHERE id IN (SELECT id FROM studies WHERE display_name IS NULL LIMIT :n)"
            ),
            {"n": BATCH_SIZE},
        ).rowcount
        if not updated:
            break


def downgrade() -> None:
    op.drop_column("studies", "display_name")
