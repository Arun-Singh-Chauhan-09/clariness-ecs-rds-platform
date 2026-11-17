#!/usr/bin/env python3
"""Block Alembic migrations that break the previous release during a rolling deploy.

ECS replaces tasks gradually, so for a few minutes the OLD and NEW app
versions run against the SAME database. Any migration that removes or renames
something the old version still uses causes errors during that window.

This guard parses each migration's upgrade() and fails on operations that are
unsafe in that window, unless the line carries an explicit, reviewed marker:

    op.drop_column("studies", "title")  # contract-approved: <why it is safe now>

Only upgrade() is checked: downgrades are destructive by design.

Usage: check_migrations.py <versions_dir> [<versions_dir> ...]
Exit code 1 if any unapproved finding exists.
"""

from __future__ import annotations

import ast
import re
import sys
from dataclasses import dataclass
from pathlib import Path

MARKER = "contract-approved:"
DANGEROUS_SQL = re.compile(r"\b(DROP\s+(COLUMN|TABLE)|RENAME\s+(COLUMN|TO)|ALTER\s+COLUMN\s+\S+\s+TYPE)\b", re.I)


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    rule: str
    message: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: [{self.rule}] {self.message}"


def _op_name(call: ast.Call) -> str | None:
    func = call.func
    if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name) and func.value.id == "op":
        return func.attr
    return None


def _kw(call: ast.Call, name: str) -> ast.expr | None:
    return next((k.value for k in call.keywords if k.arg == name), None)


def _is_false(node: ast.expr | None) -> bool:
    return isinstance(node, ast.Constant) and node.value is False


def _str_arg(call: ast.Call, index: int) -> str | None:
    if len(call.args) > index and isinstance(call.args[index], ast.Constant):
        value = call.args[index].value
        return value if isinstance(value, str) else None
    return None


def _check_call(call: ast.Call, created_tables: set[str]) -> tuple[str, str] | None:
    name = _op_name(call)
    if name is None:
        return None

    if name in ("drop_column", "drop_table"):
        return name, "removes schema the previous release may still read; use expand/contract"
    if name == "rename_table":
        return name, "rename breaks the previous release; create new + backfill + drop later"

    if name == "alter_column":
        if _kw(call, "new_column_name") is not None:
            return "rename_column", "rename breaks the previous release; add new column, dual-write, drop later"
        if _kw(call, "type_") is not None:
            return "alter_type", "type change may rewrite the table under an exclusive lock"
        if _is_false(_kw(call, "nullable")):
            return "set_not_null", "SET NOT NULL scans the table under an exclusive lock; backfill first"

    if name == "add_column" and len(call.args) >= 2 and isinstance(call.args[1], ast.Call):
        column = call.args[1]
        if _is_false(_kw(column, "nullable")) and _kw(column, "server_default") is None:
            return "add_not_null", "NOT NULL column without server_default fails or blocks inserts from the old release"

    if name == "create_index":
        table = _str_arg(call, 1) or (
            _kw(call, "table_name").value
            if isinstance(_kw(call, "table_name"), ast.Constant)
            else None
        )
        concurrently = _kw(call, "postgresql_concurrently")
        if table not in created_tables and not (isinstance(concurrently, ast.Constant) and concurrently.value):
            return "index_not_concurrent", "index on an existing table locks writes; use postgresql_concurrently=True"

    if name == "execute" and call.args:
        sql = call.args[0]
        if isinstance(sql, ast.Call) and sql.args:  # op.execute(sa.text("..."))
            sql = sql.args[0]
        if isinstance(sql, ast.Constant) and isinstance(sql.value, str) and DANGEROUS_SQL.search(sql.value):
            return "raw_sql", "raw SQL drops, renames or retypes schema"

    return None


def check_file(path: Path) -> list[Finding]:
    source = path.read_text()
    lines = source.splitlines()
    tree = ast.parse(source, filename=str(path))

    upgrade = next(
        (n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "upgrade"), None
    )
    if upgrade is None:
        return []

    calls = [n for n in ast.walk(upgrade) if isinstance(n, ast.Call)]
    created_tables = {
        t for c in calls if _op_name(c) == "create_table" and (t := _str_arg(c, 0)) is not None
    }

    findings = []
    for call in sorted(calls, key=lambda c: c.lineno):
        result = _check_call(call, created_tables)
        if result is None:
            continue
        span = lines[call.lineno - 1 : (call.end_lineno or call.lineno)]
        if any(MARKER in line for line in span):
            continue
        rule, message = result
        findings.append(Finding(str(path), call.lineno, rule, message))
    return findings


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    findings: list[Finding] = []
    files = sorted(p for d in argv for p in Path(d).glob("*.py"))
    for path in files:
        findings.extend(check_file(path))

    for finding in findings:
        print(finding)
    if findings:
        print(
            f"\n{len(findings)} unsafe migration operation(s). Split into expand/contract, "
            f"or add '# {MARKER} <reason>' on the line after review.",
            file=sys.stderr,
        )
        return 1
    print(f"OK: {len(files)} migration file(s) checked, nothing unsafe.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
