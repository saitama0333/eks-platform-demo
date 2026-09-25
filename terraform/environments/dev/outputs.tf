output "velero_backup_bucket" {
  description = "S3 bucket used by Velero for Kubernetes backups"
  value       = module.platform_aws.velero_bucket_name
}

output "sample_app_ecr_repositories" {
  description = "ECR repository URLs keyed by sample application name"
  value       = module.container_registry.repository_urls
}

output "github_actions_ecr_role_arn" {
  description = "IAM role ARN to configure as GitHub Actions variable AWS_ROLE_ARN"
  value       = module.container_registry.github_actions_role_arn
}
