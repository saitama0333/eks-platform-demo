# Same shared state bucket as dev; QA uses a different object key/prefix.
bucket       = "eks-platform-demo-tfstate-960645511169"
key          = "qa/terraform.tfstate"
region       = "ap-south-1"
encrypt      = true
use_lockfile = true
