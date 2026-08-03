locals {
  zone_name = "${var.subdomain}.${var.registered_domain}"
}

resource "aws_route53_zone" "this" {
  name    = local.zone_name
  comment = "Zona da Service Track API - persistente, nao destruir com os ambientes"

  tags = {
    Project   = "servicetrack"
    ManagedBy = "terraform"
    Lifecycle = "persistent"
  }
}
