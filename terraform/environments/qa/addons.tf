module "platform_aws" {
  source = "../../modules/platform-aws"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  cluster_name       = module.eks.cluster_name
  velero_bucket_name = var.velero_bucket_name
  velero_prefix      = var.velero_prefix

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  depends_on = [module.eks]
}

module "ecr" {
  source = "../../modules/ecr"

  project_name                = var.project_name
  environment                 = var.environment
  github_repository           = var.github_repository
  create_github_oidc_provider = var.create_github_oidc_provider
  github_oidc_provider_arn    = var.github_oidc_provider_arn

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
