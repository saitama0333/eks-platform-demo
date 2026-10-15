variable "project_name" {
  description = "Project name used in resource names"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region containing the EKS cluster and secrets"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name for Pod Identity associations"
  type        = string
}

variable "velero_bucket_name" {
  description = "Existing S3 bucket for Velero backups (shared with the Terraform state bucket)"
  type        = string
}

variable "velero_prefix" {
  description = "Environment-specific object prefix inside the Velero S3 bucket"
  type        = string

  validation {
    condition     = trim(var.velero_prefix, "/") != ""
    error_message = "Set a non-empty Velero prefix to isolate environment backups."
  }
}

variable "tags" {
  description = "Tags applied to AWS resources"
  type        = map(string)
  default     = {}
}
