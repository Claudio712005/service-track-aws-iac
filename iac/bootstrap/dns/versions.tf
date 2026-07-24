terraform {
  required_version = ">= 1.10.0"

  # State separado dos ambientes: esta zona sobrevive a destroy/apply de hml e prd.
  backend "s3" {
    bucket       = "servicetrack-tfstate-123124496645"
    key          = "servicetrack/bootstrap-dns/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
