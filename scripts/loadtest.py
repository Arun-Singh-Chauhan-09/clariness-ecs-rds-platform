#!/usr/bin/env python3
"""Tiny load generator (stdlib only) for drills: mixed reads and writes.

Prints a summary of status codes and latency percentiles at the end.
"""

import argparse
import collections
import hashlib
import json
import os
import random
import threading
import time
import urllib.error
import urllib.request

HEADERS = {"X-API-Key": os.environ.get("API_KEY", "")}


def worker(base, deadline, results, lock, study_ids, study_writes):
    while time.monotonic() < deadline:
        study_id = random.choice(study_ids)
        if random.random() < study_writes:
            code = "".join(random.choices("ABCDEFGHIJKLMNOPQRSTUVWXYZ", k=5)) + f"-2026-{random.randint(0, 999):03d}"
            req = urllib.request.Request(
                f"{base}/studies",
                method="POST",
                data=json.dumps({"code": code, "display_name": "Load test study", "phase": "II"}).encode(),
                headers={"Content-Type": "application/json", **HEADERS},
            )
        elif random.random() < 0.2:
            ref = hashlib.sha256(random.randbytes(16)).hexdigest()[:32]
            req = urllib.request.Request(
                f"{base}/studies/{study_id}/referrals",
                method="POST",
                data=json.dumps({"candidate_ref": ref, "site_code": "DE-104"}).encode(),
                headers={"Content-Type": "application/json", **HEADERS},
            )
        else:
            path = random.choice(["/studies", f"/studies/{study_id}", f"/studies/{study_id}/funnel"])
            req = urllib.request.Request(base + path, headers=HEADERS)
        start = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                code = resp.status
        except urllib.error.HTTPError as exc:
            code = exc.code
        except Exception:  # noqa: BLE001 - connection errors count as failures
            code = "conn_error"
        with lock:
            results.append((code, time.perf_counter() - start))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", default="http://localhost:8000")
    p.add_argument("--concurrency", type=int, default=20)
    p.add_argument("--duration", type=int, default=120, help="seconds")
    p.add_argument(
        "--study-writes",
        type=float,
        default=0.0,
        help="fraction of requests that create studies (POST /studies); drill 01 uses 0.2",
    )
    args = p.parse_args()
    base = args.base_url.rstrip("/")

    with urllib.request.urlopen(urllib.request.Request(f"{base}/studies", headers=HEADERS), timeout=10) as resp:
        study_ids = [s["id"] for s in json.loads(resp.read())]
    if not study_ids:
        raise SystemExit("No studies yet: run scripts/seed.py first")

    results, lock = [], threading.Lock()
    deadline = time.monotonic() + args.duration
    threads = [
        threading.Thread(target=worker, args=(base, deadline, results, lock, study_ids, args.study_writes), daemon=True)
        for _ in range(args.concurrency)
    ]
    print(f"{args.concurrency} workers for {args.duration}s against {base} ...")
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    codes = collections.Counter(str(c) for c, _ in results)
    latencies = sorted(d for _, d in results)

    def pct(q):
        return latencies[min(len(latencies) - 1, int(q * len(latencies)))] * 1000 if latencies else 0

    print(f"requests: {len(results)}  rps: {len(results) / args.duration:.1f}")
    print("status codes:", dict(codes))
    print(f"latency ms  p50={pct(0.5):.0f}  p95={pct(0.95):.0f}  p99={pct(0.99):.0f}")


if __name__ == "__main__":
    main()
