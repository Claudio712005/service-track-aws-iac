output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_cidr" {
  value = "10.10.0.0/16"
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Consumido pelo stack e pelo repositorio de banco via remote state."
  value       = module.network.private_subnet_ids
}
