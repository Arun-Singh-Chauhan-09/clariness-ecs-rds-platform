# Security

What protects the platform, layer by layer, and what is deliberately left for a
production rollout. Data here is synthetic, but the controls are designed as if
it were clinical-trial data (GDPR special-category health data).

## Controls in place

### Identity and access
| Control | Where |
|---|---|
| **API authentication**: every business endpoint requires `X-API-Key`; keys are compared as SHA-256 digests with constant-time comparison; fail closed if none are configured; minimum length 16 | `app/src/referrals/auth.py` |
| **Access audit trail**: each request is logged with a non-secret key fingerprint (`key_id`), never the key | `main.py` middleware |
| API keys live in Secrets Manager and are injected by ECS at start; rotation = add a second key, roll, remove the old one | `envs/staging/main.tf` (`api_keys`) |
| **No stored cloud credentials in CI**: GitHub Actions assumes AWS roles via OIDC | `terraform/bootstrap` |
| **Plan role** (pull requests): read-only + state access. **Deploy role**: only from the protected `staging` environment, only the services this project uses, only in the primary and DR regions; IAM limited to roles named `referrals-*` | `terraform/bootstrap/main.tf` |
| **Per-task IAM roles**: the API may write to its own log group and connect to the database as one user; Loki may use one bucket; Alertmanager may publish to one topic | `envs/staging`, `modules/observability` |

### Database
| Control | Where |
|---|---|
| **Least-privileged app role**: the API connects as `referrals_app` (SELECT/INSERT/UPDATE on its tables only: no DELETE, no DDL). Only migrations use the master user | migration `0003`, test `test_app_role_is_least_privileged` |
| **No password for the app at all**: IAM database authentication with 15-minute tokens, scoped by `rds-db:connect` to that one user | `db.py`, `envs/staging/main.tf` |
| Master password generated and rotated by RDS in Secrets Manager (KMS-encrypted); only the migration task can read it | `modules/rds-postgres` |
| TLS enforced by the server (`rds.force_ssl`) and the client (`sslmode=require`) | parameter group, `db.py` |
| Storage, snapshots and replicated backups encrypted with customer-managed KMS keys (rotation on) | `modules/rds-postgres` |
| Not publicly accessible; security group allows only the API and migration tasks | `envs/staging/main.tf` |
| Migrations fail fast on locks (`lock_timeout`), unsafe migrations blocked in CI | `migrations/env.py`, `scripts/check_migrations.py` |

### Network and edge
| Control | Where |
|---|---|
| Tasks and RDS in private subnets, no public IPs; security groups chain ALB → API → DB | `modules/network`, `modules/ecs-service` |
| **AWS WAF** on the ALB: AWS managed rules (common, known bad inputs, SQL injection, IP reputation) + per-IP rate limit | `modules/alb` |
| Internal paths (`/metrics`, `/docs`, `/openapi.json`) answered with 404 at the ALB; the app also disables docs by default | `modules/alb`, `main.py` |
| HTTPS with TLS 1.2/1.3 policy and HTTP→HTTPS redirect when a certificate is configured; HSTS sent on HTTPS requests | `modules/alb`, `main.py` |
| ALB drops invalid header fields | `modules/alb` |
| Security headers: `nosniff`, `no-store`, `no-referrer`, restrictive CSP | `main.py` |
| Default security group emptied; rejected traffic logged (VPC flow logs) | `modules/network` |
| Observability UIs not exposed; reached only through SSM port forwarding | `scripts/port-forward.sh` |

### Workload
| Control | Where |
|---|---|
| Non-root user, multi-stage slim image, OS security updates at build | `app/Dockerfile` |
| **Read-only root filesystem** for the API and migration tasks; locally also `cap_drop: ALL`, `no-new-privileges` | `envs/staging/main.tf`, `docker-compose.yml` |
| No ECS Exec into API or migration tasks | `envs/staging/main.tf` |
| Input validation: identifiers must match strict patterns, so names or e-mails are rejected (no PII accepted) | `main.py`, `test_rejects_personal_data_in_candidate_ref` |
| Parameterised SQL everywhere; errors logged by type only | `main.py` |

### Supply chain and pipeline
| Control | Where |
|---|---|
| **Trivy** image scan blocks fixable HIGH/CRITICAL CVEs (it blocked 4 on the first push) | `ci.yml` |
| **Checkov** blocks insecure Terraform; every skip has a written reason | `ci.yml`, `.checkov.yaml` |
| **gitleaks** scans the full git history for secrets | `ci.yml`, `.gitleaks.toml` |
| tflint, `terraform validate`, Prometheus rule tests | `ci.yml` |
| **Dependabot** for actions, Python packages, base images and Terraform providers | `.github/dependabot.yml` |
| Actions pinned to commit SHAs, images to digests | `scripts/pin-versions.sh` |
| Immutable, SHA-tagged images in ECR with scan on push | `envs/staging/main.tf` |
| GitHub token is read-only by default; deploys need the `staging` environment | workflows |

### Account level (bootstrap)
| Control | Where |
|---|---|
| Multi-region **CloudTrail** with log file validation, private versioned bucket | `terraform/bootstrap` |
| **GuardDuty** threat detection | `terraform/bootstrap` |
| Terraform state: versioned, KMS-encrypted, public access blocked, TLS-only | `terraform/bootstrap` |

## Known gaps: what I would add before real patient data

| Gap | Why it is not here | What I would do |
|---|---|---|
| End-user identity (OIDC/JWT, per-user roles) | API keys identify calling systems, not people | Cognito or the company IdP, JWT validation at the ALB or in the app, roles per endpoint |
| HTTPS in the demo | needs a domain + ACM certificate | set `certificate_arn`; the code already redirects and sends HSTS |
| ALB and WAF access logs | storage cost for a demo | S3 bucket with lifecycle, Athena queries |
| CMK encryption for CloudWatch logs and CloudTrail | cost/complexity for a demo | one CMK per data class |
| Security Hub, AWS Config rules | normally enabled org-wide | Organization-level delegated admin |
| Secret rotation for API keys and Grafana | manual for now | Secrets Manager rotation Lambda; Grafana behind SSO |
| GDPR mechanics (retention, deletion, data subject requests, DPIA) | product decisions, not only infra | retention jobs, delete endpoints with audit, documented processing records |
| Image signing and SBOM | not required for one repo | cosign signatures verified before deploy, SBOM from Trivy |
| Egress restriction | tasks can reach the internet through NAT | VPC endpoints for ECR, Secrets Manager, CloudWatch, then deny other egress |
