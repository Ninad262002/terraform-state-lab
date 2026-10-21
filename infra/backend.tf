terraform {
  backend "s3" {
    bucket       = "tfstate-backend-0dbfbb51"
    key          = "infra/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}