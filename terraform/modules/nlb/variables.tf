variable "name" {
  description = "Short name prefix for the Network Load Balancer and its resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC containing the EKS worker nodes"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets used by the internet-facing NLB"
  type        = list(string)
}

variable "autoscaling_group_name" {
  description = "EKS managed node group autoscaling group registered with the NLB target groups"
  type        = string
}

variable "tags" {
  description = "Tags applied to the NLB resources"
  type        = map(string)
  default     = {}
}
