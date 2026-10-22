output "dns_name" {
  description = "Public DNS name of the Network Load Balancer"
  value       = aws_lb.this.dns_name
}

output "arn" {
  description = "ARN of the Network Load Balancer"
  value       = aws_lb.this.arn
}

output "security_group_id" {
  description = "Security group attached to the Network Load Balancer"
  value       = aws_security_group.this.id
}

output "target_group_arns" {
  description = "Target group ARNs keyed by ingress protocol"
  value       = local.target_groups
}
