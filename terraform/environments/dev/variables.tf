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
  default     = "dev"
}

variable "github_repository" {
  description = "GitHub repository allowed to publish the demo application image (owner/repository)"
  type        = string
  default     = "saitama0333/eks-platform-demo"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Trusted public egress CIDRs allowed to reach the EKS Kubernetes API (use your current IP/32 for a workstation)"
  type        = list(string)

  validation {
    condition = length(var.cluster_endpoint_public_access_cidrs) > 0 && alltrue([
      for cidr in var.cluster_endpoint_public_access_cidrs : cidr != "0.0.0.0/0" && cidr != "::/0"
    ])
    error_message = "Set at least one trusted CIDR; unrestricted public EKS API access is not allowed."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the dev VPC"
  type        = string
}

variable "availability_zones" {
  description = "Availability zones used for the dev VPC subnets"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs, one per configured availability zone"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.availability_zones)
    error_message = "Provide one public subnet CIDR per availability zone."
  }
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs, one per configured availability zone"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) == length(var.availability_zones)
    error_message = "Provide one private subnet CIDR per availability zone."
  }
}

variable "single_nat_gateway" {
  description = "Use one NAT Gateway for dev to reduce cost"
  type        = bool
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
}

variable "node_instance_types" {
  description = "EC2 instance types for the core managed node group"
  type        = list(string)
}

variable "node_min_size" {
  description = "Minimum core managed node group size"
  type        = number
}

variable "node_max_size" {
  description = "Maximum core managed node group size"
  type        = number
}

variable "node_desired_size" {
  description = "Desired core managed node group size"
  type        = number
}

variable "node_disk_size" {
  description = "Root EBS volume size in GiB for dev managed nodes"
  type        = number
}

variable "velero_bucket_name" {
  description = "Existing S3 bucket shared with Terraform state"
  type        = string
  default     = "tf-gitops-nikhil"
}

variable "velero_prefix" {
  description = "Dev-specific object prefix inside the shared S3 bucket"
  type        = string
  default     = "backup/dev"
}

variable "create_github_oidc_provider" {
  description = "Create the account-wide GitHub OIDC provider from this environment; only one environment should set this true"
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "Existing account-wide GitHub OIDC provider ARN when another environment created it"
  type        = string
  default     = null
}