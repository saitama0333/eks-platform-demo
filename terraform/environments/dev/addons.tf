module "platform_aws" {
  source = "../../modules/platform-aws"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  cluster_name = module.eks.cluster_name

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  depends_on = [module.eks]
}

module "container_registry" {
  source = "../../modules/container-registry"

  project_name      = var.project_name
  environment       = var.environment
  github_repository = var.github_repository

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
