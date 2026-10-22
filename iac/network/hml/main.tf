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

data "aws_eips" "nat_reservado" {
  tags = {
    Name  = "${local.name}-nat"
    Layer = "bootstrap-rede"
  }
}

locals {
  eip_allocation_id = length(data.aws_eips.nat_reservado.allocation_ids) > 0 ? one(data.aws_eips.nat_reservado.allocation_ids) : null
}

module "network" {
  source = "../../modules/network"

  name                 = local.name
  tags                 = local.tags
  cluster_name         = local.cluster_name
  vpc_cidr             = "10.10.0.0/16"
  azs                  = ["us-east-1a", "us-east-1b"]
  public_subnet_cidrs  = ["10.10.0.0/20", "10.10.16.0/20"]
  eip_allocation_id    = local.eip_allocation_id
  private_subnet_cidrs = ["10.10.48.0/20", "10.10.64.0/20"]
}
