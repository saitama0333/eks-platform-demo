output "repository_urls" {
  description = "ECR repository URLs keyed by sample application name"
  value       = { for app_name, repository in aws_ecr_repository.apps : app_name => repository.repository_url }
}

output "github_actions_role_arn" {
  description = "OIDC role assumed by the GitHub Actions image publishing workflow"
  value       = aws_iam_role.github_actions_ecr.arn
}
