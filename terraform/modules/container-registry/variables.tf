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

variable "application_names" {
  description = "Sample application names for which ECR repositories are created"
  type        = set(string)
  default     = ["python-demo", "java-demo", "nginx-demo"]
}

variable "tags" {
  description = "Tags applied to AWS resources"
  type        = map(string)
  default     = {}
}
