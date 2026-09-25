module "vpc" {
#  source  = "terraform-aws-modules/vpc/aws"
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=v6.0.0"


  name = "${var.project_name}-${var.environment}"
  cidr = var.vpc_cidr

  azs = var.availability_zones

  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = "${var.project_name}-${var.environment}"
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}