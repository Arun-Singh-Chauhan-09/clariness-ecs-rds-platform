SHELL := /bin/bash
PYTHON ?= python3
TEST_DB := postgresql+psycopg://referrals:referrals@localhost:5432/referrals_test
TF_DIRS := terraform/bootstrap terraform/modules/network terraform/modules/alb terraform/modules/rds-postgres/examples/basic \
           terraform/modules/ecs-service terraform/modules/observability terraform/envs/staging

.PHONY: up down logs test lint check-migrations seed load promtool tf-fmt tf-validate \
        drill-01-break drill-01-fix drill-04-break drill-04-fix drill-05

up:                      ## Start the full local stack
	docker compose up -d --build
	@echo "API http://localhost:8000/docs | Grafana http://localhost:3000 (admin/admin) | Prometheus :9090 | Alertmanager :9093"

down:
	docker compose down -v

logs:
	docker compose logs -f api alert-sink

test:                    ## App tests against the local Postgres (needs `make up`)
	cd app && DATABASE_URL=$(TEST_DB) $(PYTHON) -m pytest -q
	$(PYTHON) -m pytest -q scripts/tests

lint:
	cd app && ruff check src tests ../scripts

check-migrations:
	$(PYTHON) scripts/check_migrations.py app/migrations/versions

seed:                    ## Create sample studies and referrals
	$(PYTHON) scripts/seed.py --base-url http://localhost:8000

load:                    ## 2 minutes of traffic
	$(PYTHON) scripts/loadtest.py --base-url http://localhost:8000 --concurrency 20 --duration 120

promtool:                ## Validate Prometheus config/rules and run alert unit tests
	docker run --rm -v $$PWD/observability/prometheus:/etc/prometheus --entrypoint promtool prom/prometheus:v2.55.1 \
	  check config /etc/prometheus/prometheus.local.yml
	docker run --rm -v $$PWD/observability/prometheus:/p --entrypoint promtool prom/prometheus:v2.55.1 \
	  test rules /p/tests/alerts_test.yml
	docker run --rm -v $$PWD/observability/alertmanager:/a --entrypoint amtool prom/alertmanager:v0.27.0 \
	  check-config /a/alertmanager.local.yml

tf-fmt:
	terraform fmt -recursive terraform

tf-validate:
	@for d in $(TF_DIRS); do echo "== $$d"; terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate || exit 1; done

# --- Drills (local versions; AWS versions are in docs/drills) -----------------
drill-01-break:          ## Unsafe rename migration: old code starts failing
	cp drills/unsafe_0003_rename_title.py app/migrations/versions/0003_rename_title.py
	-$(PYTHON) scripts/check_migrations.py app/migrations/versions
	docker compose run --rm -v $$PWD/app/migrations:/app/migrations migrate alembic upgrade head
	@echo "Now: $(PYTHON) scripts/loadtest.py --duration 480 --study-writes 0.2  -> POST /studies returns 500. Watch Grafana and 'make logs'."

drill-01-fix:
	docker compose run --rm -v $$PWD/app/migrations:/app/migrations migrate alembic downgrade 0002
	rm app/migrations/versions/0003_rename_title.py

drill-04-break:          ## Deploy a release that cannot reach its database
	API_DATABASE_URL=postgresql+psycopg://referrals:referrals@postgres:5432/does_not_exist docker compose up -d api
	@echo "The new API container fails its start-up DB check and exits (docker compose ps api)."
	@echo "Within ~2 min ApiTargetDown fires: watch 'make logs' and Grafana. In AWS the circuit breaker rolls back."

drill-04-fix:
	docker compose up -d api

drill-05:                ## Connection-pool exhaustion: tiny pool + load
	DB_POOL_SIZE=2 docker compose up -d api
	$(PYTHON) scripts/loadtest.py --base-url http://localhost:8000 --concurrency 40 --duration 420
	DB_POOL_SIZE=5 docker compose up -d api
