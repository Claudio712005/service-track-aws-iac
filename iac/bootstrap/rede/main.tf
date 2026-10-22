locals {
  project = "servicetrack"
}

resource "aws_eip" "nat" {
  for_each = toset(var.ambientes)

  domain = "vpc"

  tags = {
    Name        = "${local.project}-${each.key}-nat"
    Project     = local.project
    Environment = each.key
    ManagedBy   = "terraform"
    Layer       = "bootstrap-rede"
    Sobrevive   = "destroy-do-ambiente"
  }

  lifecycle {
    prevent_destroy = true
  }
}
