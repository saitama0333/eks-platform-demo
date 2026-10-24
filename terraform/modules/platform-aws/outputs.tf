output "velero_bucket_name" {
  description = "Existing S3 bucket used for Velero backups"
  value       = data.aws_s3_bucket.velero.bucket
}

output "velero_prefix" {
  description = "Environment-specific S3 object prefix used for Velero backups"
  value       = local.velero_prefix
}

output "velero_role_arn" {
  description = "Pod Identity role associated with the Velero service account"
  value       = aws_iam_role.velero.arn
}

output "external_secrets_role_arn" {
  description = "Pod Identity role associated with the External Secrets service account"
  value       = aws_iam_role.external_secrets.arn
}
