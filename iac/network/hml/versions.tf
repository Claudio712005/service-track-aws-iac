terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "servicetrack-tfstate-821146464895"
    key          = "servicetrack/hml-network/terraform.tfstate"
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
  region = var.region
}
