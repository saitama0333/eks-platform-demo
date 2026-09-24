terraform {
  backend "s3" {
    bucket       = "eks-platform-demo-tfstate-960645511169"
    key          = "dev/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true

    lifecycle {
      prevent_destroy = true
    }
  }
}