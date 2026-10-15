variable "aws_region" {
  description = "AWS region for the EKS platform and state bucket (Frankfurt)"
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "eks-platform-demo"
}