output "cluster_name" {
  value = module.stack.cluster_name
}

output "configure_kubectl" {
  value = module.stack.configure_kubectl
}

output "app_ecr_repository_url" {
  value = module.stack.app_ecr_repository_url
}

output "lambda_ecr_repository_url" {
  value = module.stack.lambda_ecr_repository_url
}

output "rds_endpoint" {
  value = module.stack.rds_endpoint
}

output "rds_jdbc_url" {
  value = module.stack.rds_jdbc_url
}

output "db_password" {
  value     = module.stack.db_password
  sensitive = true
}

output "api_gateway_url" {
  value = module.stack.api_gateway_url
}

output "api_gateway_id" {
  value = module.stack.api_gateway_id
}

output "api_consumers" {
  value = module.stack.api_consumers
}

output "api_key_values" {
  value     = module.stack.api_key_values
  sensitive = true
}

output "api_key_ids" {
  value = module.stack.api_key_ids
}

output "api_custom_domain_url" {
  value = module.stack.api_custom_domain_url
}

output "api_custom_domain_target" {
  value = module.stack.api_custom_domain_target
}

output "app_backend_nlb_dns" {
  value = module.stack.app_backend_nlb_dns
}

output "argocd_url" {
  value = module.stack.argocd_url
}

output "argocd_admin_password_cmd" {
  value = module.stack.argocd_admin_password_cmd
}
