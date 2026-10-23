output "eip_allocation_ids" {
  description = "Allocation id do EIP de cada ambiente, consumido pela camada de rede."
  value       = { for ambiente, eip in aws_eip.nat : ambiente => eip.id }
}

output "eip_public_ips" {
  description = "IP publico de cada ambiente. E o endereco a liberar em provedor externo, como a lista de IPs do MongoDB Atlas."
  value       = { for ambiente, eip in aws_eip.nat : ambiente => eip.public_ip }
}
