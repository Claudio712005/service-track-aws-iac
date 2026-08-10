output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca_data" {
  value     = module.eks.cluster_ca_data
  sensitive = true
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${data.aws_region.current.name}"
}

output "app_ecr_repository_url" {
  value = module.ecr_app.repository_url
}

output "lambda_ecr_repository_url" {
  value = module.ecr_lambda.repository_url
}

output "rds_endpoint" {
  description = "Lido do SSM publicado pelo repositorio service-track-db-infra."
  value       = local.db_endpoint
}

output "rds_jdbc_url" {
  value = "jdbc:postgresql://${local.db_endpoint}:${local.db_port}/${local.db_name}"
}

output "db_username" {
  value = local.db_username
}

output "db_password" {
  value     = local.db_password
  sensitive = true
}

output "lambda_function_name" {
  value = module.lambda_auth.function_name
}

output "api_gateway_url" {
  description = "URL base publica da API, com o stage (ex.: <url>/autenticacao)."
  value       = module.api_gateway.api_endpoint
}

output "api_gateway_id" {
  description = "ID do REST API. Preenche a variavel apiId do servers[] do openApi.yaml."
  value       = module.api_gateway.api_id
}

output "api_consumers" {
  description = "Consumidores habilitados, cada um com sua API key."
  value       = module.api_gateway.consumers
}

output "api_key_values" {
  description = "API key por consumidor. Enviar no header x-api-key."
  value       = module.api_gateway.api_key_values
  sensitive   = true
}

output "api_key_ids" {
  value = module.api_gateway.api_key_ids
}

output "jwt_authorizer_function_name" {
  description = "Funcao do authorizer de JWT, se habilitado."
  value       = var.enable_jwt_authorizer ? module.jwt_authorizer[0].function_name : null
}

output "app_backend_nlb_dns" {
  description = "DNS do NLB interno que expoe a aplicacao do EKS ao API Gateway."
  value       = module.vpc_link.nlb_dns_name
}

output "argocd_url" {
  value = module.addons.argocd_url
}

output "argocd_admin_password_cmd" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

data "aws_region" "current" {}
