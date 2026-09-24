output "interruption_queue_name" {
  value = aws_sqs_queue.karpenter_interruption.name
}

output "interruption_queue_arn" {
  value = aws_sqs_queue.karpenter_interruption.arn
}

output "node_role_name" {
  value = aws_iam_role.karpenter_node.name
}

output "node_role_arn" {
  value = aws_iam_role.karpenter_node.arn
}

output "controller_role_name" {
  value = aws_iam_role.karpenter_controller.name
}

output "controller_role_arn" {
  value = aws_iam_role.karpenter_controller.arn
}