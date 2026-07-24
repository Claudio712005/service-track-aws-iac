output "vpc_link_id" {
  description = "ID do VPC Link, usado em connectionId nas integracoes do OpenAPI."
  value       = aws_api_gateway_vpc_link.this.id
}

output "nlb_dns_name" {
  description = "DNS do NLB interno, usado como host nas URIs de integracao do OpenAPI."
  value       = aws_lb.this.dns_name
}

output "nlb_arn" {
  value = aws_lb.this.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.this.arn
}
