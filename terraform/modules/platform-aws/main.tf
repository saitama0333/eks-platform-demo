data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "aws_s3_bucket" "velero" {
  bucket = var.velero_bucket_name
}

locals {
  velero_prefix = trim(var.velero_prefix, "/")
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
    sid       = "BucketLocation"
    actions   = ["s3:GetBucketLocation"]
    resources = [data.aws_s3_bucket.velero.arn]
  }

  statement {
    sid       = "ListBackupPrefix"
    actions   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
    resources = [data.aws_s3_bucket.velero.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [local.velero_prefix, "${local.velero_prefix}/*"]
    }
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
    resources = ["${data.aws_s3_bucket.velero.arn}/${local.velero_prefix}/*"]
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
