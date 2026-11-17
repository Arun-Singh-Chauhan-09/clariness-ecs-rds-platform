#!/usr/bin/env python3
"""Create synthetic studies and referrals through the API (stdlib only)."""

import argparse
import hashlib
import json
import os
import random
import urllib.error
import urllib.request

API_KEY = os.environ.get("API_KEY", "")
STUDIES = [
    ("ONC-2026-014", "Phase II study in advanced solid tumours", "II", "Oncology"),
    ("CAR-2026-007", "Phase III heart-failure outcomes study", "III", "Cardiology"),
    ("NEU-2026-021", "Phase II early Alzheimer's disease study", "II", "Neurology"),
    ("DER-2026-003", "Phase III moderate psoriasis study", "III", "Dermatology"),
]
SITES = ["DE-104", "DE-211", "GB-031", "US-450", "RS-012"]
PROGRESS = ["referred", "contacted", "enrolled"]


def call(base: str, method: str, path: str, body: dict | None = None):
    req = urllib.request.Request(
        base + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json", "X-API-Key": API_KEY},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as exc:
        return exc.code, None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://localhost:8000")
    parser.add_argument("--referrals-per-study", type=int, default=25)
    args = parser.parse_args()
    base = args.base_url.rstrip("/")

    ids = []
    for code, name, phase, area in STUDIES:
        status, study = call(base, "POST", "/studies",
                             {"code": code, "display_name": name, "phase": phase, "therapeutic_area": area})
        if status == 201:
            ids.append(study["id"])
        elif status == 409:
            print(f"{code} exists, skipping")
        else:
            print(f"{code}: HTTP {status}")
    if not ids:
        _, existing = call(base, "GET", "/studies")
        ids = [s["id"] for s in existing or []]

    created = 0
    for study_id in ids:
        for _ in range(args.referrals_per_study):
            ref = hashlib.sha256(random.randbytes(16)).hexdigest()[:32]  # opaque token, no PII
            status, referral = call(base, "POST", f"/studies/{study_id}/referrals",
                                    {"candidate_ref": ref, "site_code": random.choice(SITES)})
            if status != 201:
                continue
            created += 1
            for step in PROGRESS[: random.randint(0, len(PROGRESS))]:
                call(base, "PATCH", f"/referrals/{referral['id']}", {"status": step})
    print(f"studies: {len(ids)}, referrals created: {created}")


if __name__ == "__main__":
    main()
