"""Trial referral API.

Models a slice of a patient-recruitment pipeline: a study is published, a
pre-screened candidate is referred to a study site, and the referral moves
through statuses until the candidate enrols or declines.

All data is synthetic. Candidates are identified only by an opaque
pseudonymous reference (a hex token); the API never accepts names, emails or
health information.
"""

from __future__ import annotations

import logging
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError

from . import metrics
from .auth import require_api_key
from .db import engine

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}',
)
log = logging.getLogger("referrals")

APP_VERSION = os.getenv("APP_VERSION", "dev")

Phase = Literal["I", "II", "III", "IV"]
Status = Literal["prescreened", "referred", "contacted", "enrolled", "declined"]

ALLOWED_TRANSITIONS: dict[str, set[str]] = {
    "prescreened": {"referred", "declined"},
    "referred": {"contacted", "declined"},
    "contacted": {"enrolled", "declined"},
    "enrolled": set(),
    "declined": set(),
}


class StudyIn(BaseModel):
    code: str = Field(pattern=r"^[A-Z]{2,5}-\d{4}-\d{3}$", examples=["ONC-2026-014"])
    display_name: str = Field(min_length=3, max_length=200)
    phase: Phase
    therapeutic_area: str | None = Field(default=None, max_length=100)


class StudyOut(StudyIn):
    id: int
    created_at: datetime


class ReferralIn(BaseModel):
    # Pseudonymous token only (e.g. a salted hash generated upstream). No PII.
    candidate_ref: str = Field(pattern=r"^[a-f0-9]{16,64}$")
    site_code: str = Field(pattern=r"^[A-Z]{2}-\d{3}$", examples=["DE-104"])


class ReferralOut(ReferralIn):
    id: int
    study_id: int
    status: Status
    created_at: datetime
    updated_at: datetime


class StatusChange(BaseModel):
    status: Status


def wait_for_database(timeout_s: float) -> None:
    """Fail fast at start-up if the database is unreachable.

    A release with a broken DB config then never becomes healthy: its new ECS
    tasks exit, the deployment circuit breaker counts the failures and rolls
    back, and the tasks of the previous release keep serving. Already-running
    tasks are not affected by a later DB outage (only start-up checks this).
    """
    deadline = time.monotonic() + timeout_s
    while True:
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            return
        except Exception as exc:  # noqa: BLE001
            if time.monotonic() >= deadline:
                log.error("database unreachable at start-up: %s", type(exc).__name__)
                raise
            time.sleep(2)


@asynccontextmanager
async def lifespan(_: FastAPI):
    log.info("starting version=%s", APP_VERSION)
    if os.getenv("STARTUP_DB_CHECK", "true") == "true":
        wait_for_database(float(os.getenv("STARTUP_DB_TIMEOUT", "30")))
    yield
    engine.dispose()
    log.info("shutdown complete")


# Interactive API docs are off unless explicitly enabled (local compose turns them on).
_docs = os.getenv("ENABLE_DOCS", "false") == "true"
app = FastAPI(
    title="referrals-api",
    version=APP_VERSION,
    lifespan=lifespan,
    docs_url="/docs" if _docs else None,
    redoc_url=None,
    openapi_url="/openapi.json" if _docs else None,
)

# Every business endpoint requires an API key; health and metrics do not
# (/metrics is blocked at the ALB and only reachable from Prometheus' SG).
api = APIRouter(dependencies=[Depends(require_api_key)])

SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
}


@app.middleware("http")
async def observe(request: Request, call_next):
    start = time.perf_counter()
    status = 500
    try:
        response: Response = await call_next(request)
        status = response.status_code
        for name, value in SECURITY_HEADERS.items():
            response.headers.setdefault(name, value)
        if request.headers.get("x-forwarded-proto") == "https":
            response.headers.setdefault("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
        return response
    finally:
        elapsed = time.perf_counter() - start
        # Label by route template ("/studies/{study_id}"), never by raw path,
        # so the metric's cardinality stays bounded.
        route = request.scope.get("route")
        route_label = getattr(route, "path", "unmatched")
        if route_label not in ("/metrics", "/healthz"):
            metrics.HTTP_REQUESTS.labels(request.method, route_label, str(status)).inc()
            metrics.HTTP_LATENCY.labels(request.method, route_label).observe(elapsed)
            # key_id is a non-secret fingerprint of the API key: an access audit trail.
            log.info(
                "method=%s route=%s status=%s duration_ms=%.1f key_id=%s",
                request.method,
                route_label,
                status,
                elapsed * 1000,
                getattr(request.state, "key_id", "-"),
            )


@app.get("/healthz")
def healthz() -> dict:
    """Liveness: the process is up. Used by the ALB target group."""
    return {"status": "ok", "version": APP_VERSION}


@app.get("/readyz")
def readyz() -> dict:
    """Readiness: the database answers and reports its schema revision."""
    try:
        with engine.connect() as conn:
            revision = conn.execute(text("SELECT version_num FROM alembic_version")).scalar()
    except Exception as exc:  # noqa: BLE001 - any DB failure means not ready
        metrics.READINESS_FAILURES.inc()
        log.warning("readiness check failed: %s", type(exc).__name__)
        raise HTTPException(status_code=503, detail="database unavailable") from exc
    return {"status": "ready", "schema_revision": revision, "version": APP_VERSION}


@app.get("/metrics")
def prometheus_metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


STUDY_COLUMNS = "id, code, display_name, phase, therapeutic_area, created_at"
REFERRAL_COLUMNS = "id, study_id, candidate_ref, site_code, status, created_at, updated_at"


@api.post("/studies", response_model=StudyOut, status_code=201)
def create_study(study: StudyIn) -> dict:
    try:
        with engine.begin() as conn:
            # Expand/contract: while the legacy `title` column exists, write it
            # too, so the previous release (which reads `title`) keeps working
            # during a rolling deployment. See docs/runbooks/db-migrations.md.
            row = conn.execute(
                text(
                    "INSERT INTO studies (code, title, display_name, phase, therapeutic_area, created_at) "
                    "VALUES (:code, :name, :name, :phase, :area, :now) "
                    f"RETURNING {STUDY_COLUMNS}"
                ),
                {
                    "code": study.code,
                    "name": study.display_name,
                    "phase": study.phase,
                    "area": study.therapeutic_area,
                    "now": datetime.now(timezone.utc),
                },
            ).mappings().one()
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="study code already exists") from exc
    return dict(row)


@api.get("/studies", response_model=list[StudyOut])
def list_studies(limit: int = 50) -> list[dict]:
    limit = max(1, min(limit, 200))
    with engine.connect() as conn:
        rows = conn.execute(
            text(f"SELECT {STUDY_COLUMNS} FROM studies ORDER BY id DESC LIMIT :limit"),
            {"limit": limit},
        ).mappings()
        return [dict(r) for r in rows]


@api.get("/studies/{study_id}", response_model=StudyOut)
def get_study(study_id: int) -> dict:
    with engine.connect() as conn:
        row = conn.execute(
            text(f"SELECT {STUDY_COLUMNS} FROM studies WHERE id = :id"), {"id": study_id}
        ).mappings().first()
    if row is None:
        raise HTTPException(status_code=404, detail="study not found")
    return dict(row)


@api.post("/studies/{study_id}/referrals", response_model=ReferralOut, status_code=201)
def create_referral(study_id: int, referral: ReferralIn) -> dict:
    now = datetime.now(timezone.utc)
    with engine.begin() as conn:
        code = conn.execute(
            text("SELECT code FROM studies WHERE id = :id"), {"id": study_id}
        ).scalar()
        if code is None:
            raise HTTPException(status_code=404, detail="study not found")
        try:
            row = conn.execute(
                text(
                    "INSERT INTO referrals (study_id, candidate_ref, site_code, status, created_at, updated_at) "
                    "VALUES (:study_id, :ref, :site, 'prescreened', :now, :now) "
                    f"RETURNING {REFERRAL_COLUMNS}"
                ),
                {"study_id": study_id, "ref": referral.candidate_ref, "site": referral.site_code, "now": now},
            ).mappings().one()
        except IntegrityError as exc:
            raise HTTPException(
                status_code=409, detail="candidate already referred to this study"
            ) from exc
    metrics.REFERRALS_CREATED.labels(code).inc()
    return dict(row)


@api.patch("/referrals/{referral_id}", response_model=ReferralOut)
def change_status(referral_id: int, change: StatusChange) -> dict:
    with engine.begin() as conn:
        current = conn.execute(
            text("SELECT status FROM referrals WHERE id = :id FOR UPDATE"), {"id": referral_id}
        ).scalar()
        if current is None:
            raise HTTPException(status_code=404, detail="referral not found")
        if change.status not in ALLOWED_TRANSITIONS[current]:
            raise HTTPException(
                status_code=422,
                detail=f"cannot move referral from '{current}' to '{change.status}'",
            )
        row = conn.execute(
            text(
                "UPDATE referrals SET status = :status, updated_at = :now WHERE id = :id "
                f"RETURNING {REFERRAL_COLUMNS}"
            ),
            {"status": change.status, "now": datetime.now(timezone.utc), "id": referral_id},
        ).mappings().one()
    metrics.REFERRAL_TRANSITIONS.labels(current, change.status).inc()
    return dict(row)


@api.get("/studies/{study_id}/funnel")
def funnel(study_id: int) -> dict:
    """Recruitment funnel: how many referrals sit in each status."""
    with engine.connect() as conn:
        exists = conn.execute(text("SELECT 1 FROM studies WHERE id = :id"), {"id": study_id}).scalar()
        if exists is None:
            raise HTTPException(status_code=404, detail="study not found")
        rows = conn.execute(
            text("SELECT status, count(*) AS n FROM referrals WHERE study_id = :id GROUP BY status"),
            {"id": study_id},
        ).all()
    counts = {status: 0 for status in ALLOWED_TRANSITIONS}
    counts.update({status: n for status, n in rows})
    return {"study_id": study_id, "funnel": counts, "total": sum(counts.values())}


app.include_router(api)
