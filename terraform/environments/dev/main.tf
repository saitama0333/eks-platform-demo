module "vpc" {
  source = "../../modules/vpc"

  project_name = var.project_name
  environment  = var.environment

  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
}

module "eks" {
  source = "../../modules/eks"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  cluster_version = var.cluster_version

  vpc_id                               = module.vpc.vpc_id
  private_subnet_ids                   = module.vpc.private_subnet_ids
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  node_instance_types = var.node_instance_types

  # Pause the dev worker ASG while the environment is idle. Revert this pause
  # change to restore the configured node_min_size and node_desired_size.
  node_min_size     = 0
  node_max_size     = var.node_max_size
  node_desired_size = 0
  node_disk_size    = var.node_disk_size
}

module "karpenter" {
  source = "../../modules/karpenter"

  aws_region   = var.aws_region
  cluster_name = module.eks.cluster_name
  cluster_arn  = module.eks.cluster_arn

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  depends_on = [module.eks]
}

module "ingress_nlb" {
  source = "../../modules/nlb"

  name                   = "${var.project_name}-${var.environment}"
  vpc_id                 = module.vpc.vpc_id
  public_subnet_ids      = module.vpc.public_subnet_ids
  autoscaling_group_name = try(module.eks.managed_node_group_autoscaling_group_names[0], "")
  attach_to_asg           = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ingress_http_nodeport" {
  security_group_id            = module.eks.node_security_group_id
  referenced_security_group_id = module.ingress_nlb.security_group_id
  from_port                    = 30080
  to_port                      = 30080
  ip_protocol                  = "tcp"
  description                  = "HTTP from the dev ingress NLB"
}

resource "aws_vpc_security_group_ingress_rule" "ingress_https_nodeport" {
  security_group_id            = module.eks.node_security_group_id
  referenced_security_group_id = module.ingress_nlb.security_group_id
  from_port                    = 30443
  to_port                      = 30443
  ip_protocol                  = "tcp"
  description                  = "HTTPS from the dev ingress NLB"
}
