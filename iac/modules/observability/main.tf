terraform {
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "4.1.0"
    }
  }
  required_version = ">= 1.1.5"
}

provider "datadog" {
  api_key = var.datadog_api_key
  app_key = var.datadog_app_key
}