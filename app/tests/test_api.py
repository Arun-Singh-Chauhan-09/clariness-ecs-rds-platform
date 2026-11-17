STUDY = {"code": "ONC-2026-014", "display_name": "Phase II oncology study", "phase": "II"}
CANDIDATE = "a3f1c9e2b7d4a6f80011"


def create_study(client, **overrides):
    resp = client.post("/studies", json={**STUDY, **overrides})
    assert resp.status_code == 201, resp.text
    return resp.json()


def test_health_and_readiness(client):
    assert client.get("/healthz").json()["status"] == "ok"
    ready = client.get("/readyz")
    assert ready.status_code == 200
    assert ready.json()["schema_revision"] == "0003"


def test_create_and_get_study(client):
    study = create_study(client)
    assert client.get(f"/studies/{study['id']}").json()["display_name"] == STUDY["display_name"]
    assert [s["code"] for s in client.get("/studies").json()] == [STUDY["code"]]


def test_duplicate_study_code_conflicts(client):
    create_study(client)
    assert client.post("/studies", json=STUDY).status_code == 409


def test_study_writes_legacy_title_for_previous_release(client):
    """Expand/contract: the old release still reads `title`, so it must be populated."""
    from sqlalchemy import text

    from referrals.db import engine

    study = create_study(client)
    with engine.connect() as conn:
        title = conn.execute(text("SELECT title FROM studies WHERE id = :id"), {"id": study["id"]}).scalar()
    assert title == STUDY["display_name"]


def test_rejects_personal_data_in_candidate_ref(client):
    study = create_study(client)
    resp = client.post(
        f"/studies/{study['id']}/referrals",
        json={"candidate_ref": "jane.doe@example.com", "site_code": "DE-104"},
    )
    assert resp.status_code == 422


def test_referral_lifecycle_and_funnel(client):
    study = create_study(client)
    ref = client.post(
        f"/studies/{study['id']}/referrals", json={"candidate_ref": CANDIDATE, "site_code": "DE-104"}
    ).json()
    assert ref["status"] == "prescreened"

    for status in ("referred", "contacted", "enrolled"):
        resp = client.patch(f"/referrals/{ref['id']}", json={"status": status})
        assert resp.status_code == 200, resp.text

    funnel = client.get(f"/studies/{study['id']}/funnel").json()
    assert funnel["funnel"]["enrolled"] == 1
    assert funnel["total"] == 1


def test_invalid_transition_rejected(client):
    study = create_study(client)
    ref = client.post(
        f"/studies/{study['id']}/referrals", json={"candidate_ref": CANDIDATE, "site_code": "DE-104"}
    ).json()
    resp = client.patch(f"/referrals/{ref['id']}", json={"status": "enrolled"})
    assert resp.status_code == 422


def test_duplicate_referral_conflicts(client):
    study = create_study(client)
    body = {"candidate_ref": CANDIDATE, "site_code": "DE-104"}
    assert client.post(f"/studies/{study['id']}/referrals", json=body).status_code == 201
    assert client.post(f"/studies/{study['id']}/referrals", json=body).status_code == 409


def test_metrics_use_route_templates(client):
    study = create_study(client)
    client.get(f"/studies/{study['id']}")
    body = client.get("/metrics").text
    assert 'route="/studies/{study_id}"' in body
    assert "db_pool_checked_out" in body
