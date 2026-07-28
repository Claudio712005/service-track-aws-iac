terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "servicetrack-tfstate-123124496645"
    key          = "servicetrack/hml/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.39"
    }
  }
}

provider "datadog" {
  api_key  = var.datadog_api_key
  app_key  = var.datadog_app_key
  api_url  = "https://api.${var.datadog_site}/"
  validate = var.datadog_api_key != ""
}
