"""DRILL 01 ONLY - the unsafe migration. Do not merge.

Renames studies.title -> studies.name in one step. The release that is still
running during a rolling deploy INSERTs into `title`, so every POST /studies
returns 500 until all tasks are replaced (or forever, if the new release
fails and ECS rolls back to the old one).

See docs/drills/01-unsafe-migration.md.

Revision ID: 9001
Revises: 0003
"""
from alembic import op

revision = "9001"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column("studies", "title", new_column_name="name")


def downgrade() -> None:
    op.alter_column("studies", "name", new_column_name="title")
