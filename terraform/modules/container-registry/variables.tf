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
