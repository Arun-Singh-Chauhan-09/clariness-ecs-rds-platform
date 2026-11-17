"""CONTRACT: drop the legacy studies.title column.

NOT in migrations/versions on purpose. Promote this file only when:
  1. every running task is on a release that no longer reads `title`
     (check: aws ecs describe-services -> only one deployment, PRIMARY), and
  2. the app code has stopped writing `title` (remove it from the INSERT in
     src/referrals/main.py in the same PR that promotes this file).
Then: git mv migrations/pending/0003_contract_drop_title.py migrations/versions/

Revision ID: 0003
Revises: 0002
Create Date: 2026-11-17
"""
import sqlalchemy as sa
from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Full-table scan under an ACCESS EXCLUSIVE lock; fine at this table size.
    op.alter_column("studies", "display_name", nullable=False)  # contract-approved: backfilled in 0002
    op.drop_column("studies", "title")  # contract-approved: all readers moved to display_name in 0002


def downgrade() -> None:
    op.add_column("studies", sa.Column("title", sa.String(200), nullable=True))
    op.execute("UPDATE studies SET title = display_name")
    op.alter_column("studies", "title", nullable=False)
    op.alter_column("studies", "display_name", nullable=True)
