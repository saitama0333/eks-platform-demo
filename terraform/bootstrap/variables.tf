variable "aws_region" {
  description = "AWS region for the EKS platform and state bucket (Frankfurt)"
  type        = string
  default     = "eu-central-1"
}

variable "aws_account_id" {
  description = "12-digit AWS account ID that must own the bootstrap resources"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Set aws_account_id to the 12-digit ID of the target AWS account."
  }
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "eks-platform-demo"
}