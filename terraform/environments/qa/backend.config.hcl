# Same shared state bucket as dev; QA uses a different object key/prefix.
bucket       = "tf-gitops-nikhil"
key          = "qa/terraform.tfstate"
region       = "ap-south-1"
encrypt      = true
use_lockfile = true
