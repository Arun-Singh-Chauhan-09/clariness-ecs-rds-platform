"""Verify a restored database (used by scripts/dr-restore-drill.sh).

Runs as a one-off ECS task pointed at the restored RDS instance, because the
database is only reachable from inside the VPC. Prints one JSON line that the
drill script reads from the task logs, and exits non-zero if the restore
looks wrong.
"""

from __future__ import annotations

import json
import os
import sys

from sqlalchemy import text

from .db import engine


def main() -> int:
    min_studies = int(os.getenv("MIN_EXPECTED_STUDIES", "1"))
    with engine.connect() as conn:
        result = {
            "schema_revision": conn.execute(text("SELECT version_num FROM alembic_version")).scalar(),
            "studies": conn.execute(text("SELECT count(*) FROM studies")).scalar(),
            "referrals": conn.execute(text("SELECT count(*) FROM referrals")).scalar(),
            "latest_referral_at": str(
                conn.execute(text("SELECT max(created_at) FROM referrals")).scalar()
            ),
        }
    result["ok"] = result["studies"] >= min_studies
    print("DR_VERIFY " + json.dumps(result), flush=True)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
