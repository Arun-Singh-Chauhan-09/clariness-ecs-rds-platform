"""Prometheus metrics for the referrals API."""

from __future__ import annotations

import time

from prometheus_client import REGISTRY, Counter, Histogram
from prometheus_client.core import GaugeMetricFamily
from prometheus_client.registry import Collector
from sqlalchemy import create_engine, pool, text

from .db import database_url, engine

# Separate, unpooled engine for the scrape-time probe, so a saturated app pool
# shows up as pool saturation and not as "database down".
_probe_engine = create_engine(database_url(), poolclass=pool.NullPool)

HTTP_REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests by route template, method and status code.",
    ["method", "route", "status"],
)

HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency by route template.",
    ["method", "route"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

READINESS_FAILURES = Counter(
    "readiness_failures_total",
    "/readyz calls that failed because the database was unreachable.",
)

REFERRALS_CREATED = Counter(
    "referrals_created_total",
    "Referrals created, by study code.",
    ["study_code"],
)

REFERRAL_TRANSITIONS = Counter(
    "referral_status_transitions_total",
    "Referral status changes.",
    ["from_status", "to_status"],
)


class DbPoolCollector(Collector):
    """Exposes SQLAlchemy connection-pool usage at scrape time."""

    def collect(self):
        pool = engine.pool
        size = GaugeMetricFamily("db_pool_size", "Configured connection pool size.")
        size.add_metric([], pool.size())
        yield size
        checked_out = GaugeMetricFamily("db_pool_checked_out", "Connections currently in use.")
        checked_out.add_metric([], pool.checkedout())
        yield checked_out
        overflow = GaugeMetricFamily("db_pool_overflow", "Connections opened beyond pool_size.")
        overflow.add_metric([], max(pool.overflow(), 0))
        yield overflow


REGISTRY.register(DbPoolCollector())


class DbProbeCollector(Collector):
    """db_up: 1 if this task can run SELECT 1 right now. Evaluated on every scrape."""

    def collect(self):
        start = time.perf_counter()
        try:
            with _probe_engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            up = 1
        except Exception:  # noqa: BLE001 - any failure means the DB is unreachable from here
            up = 0
        up_metric = GaugeMetricFamily("db_up", "Whether this task can reach the database (1) or not (0).")
        up_metric.add_metric([], up)
        yield up_metric
        latency = GaugeMetricFamily("db_probe_seconds", "Duration of the last SELECT 1 probe.")
        latency.add_metric([], time.perf_counter() - start)
        yield latency


REGISTRY.register(DbProbeCollector())
