output "zone_id" {
  value = aws_route53_zone.this.zone_id
}

output "zone_name" {
  description = "Passar como custom_domain.hosted_zone_name nos ambientes."
  value       = aws_route53_zone.this.name
}

output "name_servers" {
  description = "Servidores a cadastrar como NS do subdominio no painel do Registro.br."
  value       = aws_route53_zone.this.name_servers
}

output "registro_br_instrucoes" {
  description = "Passo a passo da delegacao. Executar uma unica vez."
  value       = <<-EOT

    Delegue ${local.zone_name} no Registro.br -- uma unica vez.

      1. registro.br > Painel > ${var.registered_domain} > DNS > Editar zona
      2. Crie um registro NS para cada servidor abaixo, com o nome "${var.subdomain}":

    ${join("\n    ", formatlist("%s  IN  NS  %s", var.subdomain, aws_route53_zone.this.name_servers))}

      3. Salve e aguarde a propagacao (minutos a algumas horas). Confirme com:

           dig +short NS ${local.zone_name}

         A resposta deve listar os quatro servidores acima.

    Depois disso o Registro.br nao precisa mais ser tocado: os ambientes podem
    ser destruidos e recriados a vontade que o alias e refeito dentro desta zona.

    Nos ambientes, use:

      custom_domain = {
        domain_name      = "${local.zone_name}"          # prd
        hosted_zone_name = "${local.zone_name}"
        base_path        = "service-track/v1"
      }
  EOT
}
