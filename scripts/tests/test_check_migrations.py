import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import check_migrations  # noqa: E402


def write(tmp_path: Path, body: str) -> Path:
    path = tmp_path / "m.py"
    path.write_text("from alembic import op\nimport sqlalchemy as sa\n\n" + body)
    return path


def rules(path: Path) -> list[str]:
    return [f.rule for f in check_migrations.check_file(path)]


def test_repo_migrations_are_safe():
    assert check_migrations.main([str(ROOT / "app/migrations/versions")]) == 0


def test_pending_contract_migration_is_approved():
    assert rules(ROOT / "app/migrations/pending/0003_contract_drop_title.py") == []


def test_drill_rename_is_blocked():
    assert rules(ROOT / "drills/unsafe_0003_rename_title.py") == ["rename_column"]


@pytest.mark.parametrize(
    "body, expected",
    [
        ('def upgrade():\n    op.drop_column("t", "c")\n', ["drop_column"]),
        ('def upgrade():\n    op.drop_table("t")\n', ["drop_table"]),
        ('def upgrade():\n    op.rename_table("a", "b")\n', ["rename_table"]),
        ('def upgrade():\n    op.alter_column("t", "c", type_=sa.Text())\n', ["alter_type"]),
        ('def upgrade():\n    op.alter_column("t", "c", nullable=False)\n', ["set_not_null"]),
        (
            'def upgrade():\n    op.add_column("t", sa.Column("c", sa.Integer, nullable=False))\n',
            ["add_not_null"],
        ),
        (
            'def upgrade():\n    op.add_column("t", sa.Column("c", sa.Integer, nullable=False, server_default="0"))\n',
            [],
        ),
        ('def upgrade():\n    op.create_index("ix", "t", ["c"])\n', ["index_not_concurrent"]),
        (
            'def upgrade():\n    op.create_index("ix", "t", ["c"], postgresql_concurrently=True)\n',
            [],
        ),
        (
            'def upgrade():\n'
            '    op.create_table("t", sa.Column("c", sa.Integer))\n'
            '    op.create_index("ix", "t", ["c"])\n',
            [],
        ),
        ('def upgrade():\n    op.execute("ALTER TABLE t DROP COLUMN c")\n', ["raw_sql"]),
        ('def upgrade():\n    op.execute(sa.text("ALTER TABLE t RENAME COLUMN a TO b"))\n', ["raw_sql"]),
        ('def upgrade():\n    op.drop_column("t", "c")  # contract-approved: unused since v3\n', []),
        ('def upgrade():\n    pass\n\ndef downgrade():\n    op.drop_column("t", "c")\n', []),
    ],
)
def test_rules(tmp_path, body, expected):
    assert rules(write(tmp_path, body)) == expected
