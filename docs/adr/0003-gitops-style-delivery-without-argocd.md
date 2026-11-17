# ADR 0003: GitOps-style delivery to ECS without ArgoCD

**Status:** accepted · **Date:** 2026-11

## Context
On Kubernetes we would use ArgoCD: git holds the desired state, a controller
applies it, and drift is detected continuously. ArgoCD cannot target ECS.

## Decision
Keep the GitOps properties, implemented with Terraform and GitHub Actions:

| GitOps property | ArgoCD on EKS | Here |
|---|---|---|
| Git is the source of truth | manifests in git | Terraform + the image tag = commit SHA on `main` |
| Changes are reviewed | PR diff of manifests | PR comment with `terraform plan` (`terraform-plan.yml`) |
| Automatic reconciliation | controller sync loop | `deploy.yml` applies on every merge to `main` |
| Safe rollout and rollback | Argo Rollouts | ECS deployment circuit breaker with rollback; `apply` waits for steady state and fails the pipeline |
| Drift detection | continuous diff | daily `terraform plan -detailed-exitcode`, opens an issue (`drift.yml`) |
| No cluster credentials in CI | pull model | OIDC role, scoped to the `staging` GitHub environment |

## Consequences
- Reconciliation is push-based and runs on merge, not continuously: a console
  change is reverted on the next deploy and reported within a day by the drift check.
- Database migrations are an explicit pipeline step that runs before the
  service update (ArgoCD would use a PreSync hook for the same thing).
- Rollback = revert the commit. The pipeline redeploys the previous SHA.
