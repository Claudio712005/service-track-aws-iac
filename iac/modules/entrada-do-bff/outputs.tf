output "nlb_dns_name" {
  value = aws_lb.this.dns_name
}

output "vpc_link_id" {
  value = aws_api_gateway_vpc_link.this.id
}

output "bff_integration_uri" {
  description = "Base que a borda publica usa para integrar /bff por VPC Link."
  value       = "http://${aws_lb.this.dns_name}:${var.bff.node_port}"
}

output "verificacao_de_credencial_url" {
  description = "Base que a Lambda de autenticacao usa para chamar a verificacao de credencial. Nula quando o alvo nao existe."
  value       = var.verificacao_de_credencial == null ? null : "http://${aws_lb.this.dns_name}:${var.verificacao_de_credencial.node_port}"
}
