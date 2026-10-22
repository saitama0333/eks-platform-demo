terraform {
  backend "s3" {
    bucket       = "tf-gitops-nikhil"
    key          = "qa/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
