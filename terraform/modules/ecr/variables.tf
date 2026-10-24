variable "project_name" {
  description = "Project name used in resource names"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "github_repository" {
  description = "GitHub repository allowed to publish images, in owner/repository format"
  type        = string
}

variable "create_github_oidc_provider" {
  description = "Create the account-wide GitHub Actions OIDC provider; set false for additional environments sharing the existing provider"
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "Existing account-wide GitHub Actions OIDC provider ARN, required when create_github_oidc_provider is false"
  type        = string
  default     = null

  validation {
    condition     = var.create_github_oidc_provider || (var.github_oidc_provider_arn != null && var.github_oidc_provider_arn != "")
    error_message = "Set github_oidc_provider_arn when reusing the account's existing GitHub OIDC provider."
  }
}

variable "gitlab_project_path" {
  description = "GitLab namespace/project path allowed to publish images"
  type        = string
  default     = "saitama0333/eks-platform-demo"
}

variable "enable_gitlab_oidc" {
  description = "Allow GitLab CI OIDC to assume this environment's ECR publishing role"
  type        = bool
  default     = false
}

variable "create_gitlab_oidc_provider" {
  description = "Create the account-wide GitLab.com OIDC provider; set true in only one environment"
  type        = bool
  default     = false
}

variable "gitlab_oidc_provider_arn" {
  description = "Existing account-wide GitLab.com OIDC provider ARN when not creating it here"
  type        = string
  default     = null

  validation {
    condition     = !var.enable_gitlab_oidc || var.create_gitlab_oidc_provider || (var.gitlab_oidc_provider_arn != null && var.gitlab_oidc_provider_arn != "")
    error_message = "When GitLab OIDC is enabled, create its provider or set gitlab_oidc_provider_arn."
  }
}

variable "application_names" {
  description = "Sample applications for which ECR repositories are created"
  type        = set(string)
  default     = ["python-demo", "java-demo", "nginx-demo"]
}

variable "tags" {
  description = "Tags applied to AWS resources"
  type        = map(string)
  default     = {}
}
