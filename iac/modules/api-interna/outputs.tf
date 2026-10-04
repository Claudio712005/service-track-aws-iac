output "rest_api_id" {
  value = aws_api_gateway_rest_api.this.id
}

output "vpc_endpoint_id" {
  value = aws_vpc_endpoint.execute_api.id
}

output "nlb_dns_name" {
  value = aws_lb.this.dns_name
}

output "vpc_link_id" {
  value = aws_api_gateway_vpc_link.this.id
}

output "url_privada" {
  description = "Resolve apenas de dentro da VPC, pelo DNS privado do endpoint de interface."
  value       = "https://${aws_api_gateway_rest_api.this.id}.execute-api.${var.region}.amazonaws.com/${aws_api_gateway_stage.this.stage_name}"
}

output "url_por_endpoint" {
  description = "Forma explicita pelo endpoint, valida mesmo com o DNS privado desligado."
  value       = "https://${aws_api_gateway_rest_api.this.id}-${aws_vpc_endpoint.execute_api.id}.execute-api.${var.region}.amazonaws.com/${aws_api_gateway_stage.this.stage_name}"
}

output "bases_dos_servicos" {
  description = "Base de cada servico na API interna, para a configuracao do BFF."
  value = {
    for nome, s in local.servicos :
    nome => "https://${aws_api_gateway_rest_api.this.id}.execute-api.${var.region}.amazonaws.com/${aws_api_gateway_stage.this.stage_name}/${nome}"
  }
}
