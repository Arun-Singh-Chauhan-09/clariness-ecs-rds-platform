output "state_bucket" {
  description = "Use as `bucket` in terraform/envs/staging/backend.hcl."
  value       = aws_s3_bucket.state.id
}

output "plan_role_arn" {
  description = "GitHub secret AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}

output "deploy_role_arn" {
  description = "GitHub secret AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}
