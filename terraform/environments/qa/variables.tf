variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "eks-platform-demo"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "qa"
}

variable "github_repository" {
  description = "GitHub repository allowed to publish application images, in owner/repository format"
  type        = string
  default     = "saitama0333/eks-platform-demo"
}

variable "github_oidc_provider_arn" {
  description = "GitHub OIDC provider ARN output from the dev root; the provider is account-wide and must not be created twice"
  type        = string
}

variable "velero_bucket_name" {
  description = "Optional explicit globally unique Velero S3 bucket name; leave null to derive it from the active AWS account"
  type        = string
  default     = null
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Trusted public egress CIDRs allowed to reach the QA EKS API endpoint"
  type        = list(string)

  validation {
    condition = length(var.cluster_endpoint_public_access_cidrs) > 0 && alltrue([
      for cidr in var.cluster_endpoint_public_access_cidrs : cidr != "0.0.0.0/0" && cidr != "::/0"
    ])
    error_message = "Set at least one trusted CIDR; unrestricted public EKS API access is not allowed."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the QA VPC; must not overlap with peered or connected networks"
  type        = string
}

variable "availability_zones" {
  description = "Availability zones used for the QA VPC subnets"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Public QA subnet CIDRs, one per configured availability zone"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.availability_zones)
    error_message = "Provide one public subnet CIDR per availability zone."
  }
}

variable "private_subnet_cidrs" {
  description = "Private QA subnet CIDRs, one per configured availability zone"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) == length(var.availability_zones)
    error_message = "Provide one private subnet CIDR per availability zone."
  }
}

variable "single_nat_gateway" {
  description = "Use one NAT Gateway for QA to reduce cost"
  type        = bool
}

variable "cluster_version" {
  description = "Kubernetes version for the QA EKS cluster"
  type        = string
}

variable "node_instance_types" {
  description = "EC2 instance types for the QA core managed node group"
  type        = list(string)
}

variable "node_min_size" {
  description = "Minimum QA core managed node group size"
  type        = number
}

variable "node_max_size" {
  description = "Maximum QA core managed node group size"
  type        = number
}

variable "node_desired_size" {
  description = "Desired QA core managed node group size"
  type        = number
}

variable "node_disk_size" {
  description = "Root EBS volume size in GiB for QA managed nodes"
  type        = number
}
