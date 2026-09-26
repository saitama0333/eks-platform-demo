terraform {
  backend "s3" {
    bucket       = "tf-gitops-nikhil"
    key          = "dev/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}