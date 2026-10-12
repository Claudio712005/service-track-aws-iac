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
