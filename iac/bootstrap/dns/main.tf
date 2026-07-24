# Hosted zone da API. PERSISTENTE: fica fora do state dos ambientes de proposito.
#
# Os name servers desta zona sao delegados uma unica vez no painel do Registro.br.
# Se a zona fosse criada junto com hml/prd, cada `terraform destroy` geraria um
# conjunto novo de NS e exigiria reconfigurar o Registro.br na mao -- exatamente
# o passo manual que a arquitetura quer eliminar. Ver ADR-008.
#
# Delegando apenas um subdominio, o restante do dominio (site, e-mail) continua
# sendo servido pelo Registro.br.
#
#   prd -> <sub>.<dominio>        (apice da zona)
#   hml -> hml.<sub>.<dominio>
#
# Este diretorio so e aplicado uma vez. Nao entra no ciclo destroy/apply.

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
