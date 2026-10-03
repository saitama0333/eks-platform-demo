output "velero_backup_bucket" {
  description = "Existing S3 bucket used by Velero for QA Kubernetes backups"
  value       = module.platform_aws.velero_bucket_name
}

output "velero_backup_prefix" {
  description = "QA-specific S3 prefix used by Velero"
  value       = module.platform_aws.velero_prefix
}

output "sample_app_ecr_repositories" {
  description = "QA ECR repository URLs keyed by sample application name"
  value       = module.ecr.repository_urls
}

output "github_actions_ecr_role_arn" {
  description = "IAM role ARN to configure as GitHub Actions variable AWS_ROLE_ARN_QA"
  value       = module.ecr.github_actions_role_arn
}

output "github_oidc_provider_arn" {
  description = "Account-wide GitHub Actions OIDC provider ARN for reuse by dev"
  value       = module.ecr.github_oidc_provider_arn
}
