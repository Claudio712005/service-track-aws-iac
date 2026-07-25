output "parameter_names" {
  value = [for p in aws_ssm_parameter.this : p.name]
}

output "name_prefix" {
  value = var.name_prefix
}
