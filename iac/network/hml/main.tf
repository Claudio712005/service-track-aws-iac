locals {
  project      = "servicetrack"
  environment  = "hml"
  name         = "${local.project}-${local.environment}"
  cluster_name = local.name

  tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
    Layer       = "network"
  }
}

module "network" {
  source = "../../modules/network"

  name                 = local.name
  tags                 = local.tags
  cluster_name         = local.cluster_name
  vpc_cidr             = "10.10.0.0/16"
  azs                  = ["us-east-1a", "us-east-1b"]
  public_subnet_cidrs  = ["10.10.0.0/20", "10.10.16.0/20"]
  private_subnet_cidrs = ["10.10.48.0/20", "10.10.64.0/20"]
}
