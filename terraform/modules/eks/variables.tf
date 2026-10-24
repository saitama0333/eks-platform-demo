variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "addon_versions" {
  description = "Optional explicit versions for all EKS managed add-ons; when omitted, select the latest compatible AWS-published versions."
  type        = map(string)
  default     = null

  validation {
    condition = var.addon_versions == null || alltrue([
      for name in ["vpc-cni", "coredns", "kube-proxy", "eks-pod-identity-agent", "aws-ebs-csi-driver"] :
      contains(keys(var.addon_versions), name) && var.addon_versions[name] != ""
    ])
    error_message = "When pinning add-ons, provide a non-empty version for every managed add-on."
  }
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs"
  type        = list(string)
}

variable "node_instance_types" {
  description = "Managed node group instance types"
  type        = list(string)
  default     = ["t3.micro"]
}

variable "node_desired_size" {
  description = "Desired number of managed nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of managed nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of managed nodes"
  type        = number
  default     = 3
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Trusted IPv4/IPv6 CIDRs allowed to reach the public EKS API endpoint"
  type        = list(string)

  validation {
    condition = length(var.cluster_endpoint_public_access_cidrs) > 0 && alltrue([
      for cidr in var.cluster_endpoint_public_access_cidrs : cidr != "0.0.0.0/0" && cidr != "::/0"
    ])
    error_message = "Set at least one trusted CIDR; unrestricted public EKS API access is not allowed."
  }
}

variable "node_disk_size" {
  description = "Root EBS volume size in GiB for managed worker nodes"
  type        = number
  default     = 20
}
