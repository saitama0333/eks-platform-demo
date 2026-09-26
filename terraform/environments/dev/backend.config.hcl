# Shared state bucket; dev state is isolated by its object key.
bucket       = "tf-gitops-nikhil"
key          = "dev/terraform.tfstate"
region       = "ap-south-1"
encrypt      = true
use_lockfile = true
