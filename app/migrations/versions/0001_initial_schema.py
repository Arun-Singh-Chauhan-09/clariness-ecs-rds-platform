"""Initial schema: studies and referrals.

Revision ID: 0001
Revises:
Create Date: 2026-11-17
"""
import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "studies",
        sa.Column("id", sa.BigInteger, sa.Identity(), primary_key=True),
        sa.Column("code", sa.String(20), nullable=False, unique=True),
        # Legacy name column. Release 2 adds `display_name`; `title` is removed
        # only in a later release (see migrations/pending/).
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("phase", sa.String(3), nullable=False),
        sa.Column("therapeutic_area", sa.String(100)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "referrals",
        sa.Column("id", sa.BigInteger, sa.Identity(), primary_key=True),
        sa.Column(
            "study_id",
            sa.BigInteger,
            sa.ForeignKey("studies.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("candidate_ref", sa.String(64), nullable=False),
        sa.Column("site_code", sa.String(10), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("study_id", "candidate_ref", name="uq_referral_candidate_per_study"),
        sa.CheckConstraint(
            "status IN ('prescreened','referred','contacted','enrolled','declined')",
            name="ck_referral_status",
        ),
    )
    op.create_index("ix_referrals_study_status", "referrals", ["study_id", "status"])


def downgrade() -> None:
    op.drop_index("ix_referrals_study_status", table_name="referrals")
    op.drop_table("referrals")
    op.drop_table("studies")
