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
  description = "Optional explicit globally unique Velero S3 bucket name; when null, derive it from project, environment, and the current AWS account"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to AWS resources"
  type        = map(string)
  default     = {}
}
