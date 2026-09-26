data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  velero_bucket_name = var.velero_bucket_name != null && trimspace(var.velero_bucket_name) != "" ? var.velero_bucket_name : "${var.project_name}-${var.environment}-velero-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "velero" {
  bucket = local.velero_bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(var.tags, { Name = local.velero_bucket_name })
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket = aws_s3_bucket.velero.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "velero" {
  bucket = aws_s3_bucket.velero.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "pod_identity_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole", "sts:TagSession"]
  }
}

resource "aws_iam_role" "velero" {
  name               = "${var.project_name}-${var.environment}-velero"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "velero" {
  statement {
    sid       = "BucketMetadataAndListing"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.velero.arn]
  }

  statement {
    sid = "BackupObjectAccess"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.velero.arn}/*"]
  }
}

resource "aws_iam_role_policy" "velero" {
  name   = "${var.project_name}-${var.environment}-velero-s3"
  role   = aws_iam_role.velero.id
  policy = data.aws_iam_policy_document.velero.json
}

resource "aws_eks_pod_identity_association" "velero" {
  cluster_name    = var.cluster_name
  namespace       = "velero"
  service_account = "velero"
  role_arn        = aws_iam_role.velero.arn
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.project_name}-${var.environment}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid = "ReadEnvironmentSecrets"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/${var.environment}/*"
    ]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "${var.project_name}-${var.environment}-external-secrets-read"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = var.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}
