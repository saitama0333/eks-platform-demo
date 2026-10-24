variable "aws_region" {
  description = "AWS region for QA resources (Frankfurt)"
  type        = string
  default     = "eu-central-1"
}

variable "aws_account_id" {
  description = "12-digit AWS account ID that must own the QA resources"
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
  description = "Existing account-wide GitHub OIDC provider ARN when another environment created it"
  type        = string
  default     = null
}

variable "create_github_oidc_provider" {
  description = "Create the account-wide GitHub OIDC provider from QA when no other environment has created it"
  type        = bool
  default     = false
}

variable "gitlab_project_path" {
  description = "GitLab namespace/project path allowed to publish application images"
  type        = string
  default     = "saitama0333/eks-platform-demo"
}

variable "enable_gitlab_oidc" {
  description = "Allow GitLab CI to publish images with OIDC; opt in only after configuring the GitLab project"
  type        = bool
  default     = false
}

variable "create_gitlab_oidc_provider" {
  description = "Create the account-wide GitLab OIDC provider from QA only when dev is not creating it"
  type        = bool
  default     = false
}

variable "gitlab_oidc_provider_arn" {
  description = "Existing account-wide GitLab OIDC provider ARN when another environment created it"
  type        = string
  default     = null
}

variable "velero_bucket_name" {
  description = "Existing S3 bucket shared with Terraform state"
  type        = string
  default     = "tf-gitops-nikhil"
}

variable "velero_prefix" {
  description = "QA-specific object prefix inside the shared S3 bucket"
  type        = string
  default     = "backup/qa"
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

variable "eks_addon_versions" {
  description = "Pinned EKS add-on builds compatible with Kubernetes 1.33; review on cluster/add-on upgrades"
  type        = map(string)
  default = {
    vpc-cni                = "v1.23.2-eksbuild.6"
    coredns                = "v1.13.2-eksbuild.59"
    kube-proxy             = "v1.33.10-eksbuild.59"
    eks-pod-identity-agent = "v1.4.1-eksbuild.2"
    aws-ebs-csi-driver     = "v1.67.1-eksbuild.1"
  }
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
