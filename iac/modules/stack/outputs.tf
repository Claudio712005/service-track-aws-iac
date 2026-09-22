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

output "argocd_url" {
  value = module.addons.argocd_url
}

output "argocd_admin_password_cmd" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

output "lambda_ecr_repository_url" {
  value = one(module.ecr_lambda[*].repository_url)
}

output "lambda_function_name" {
  value = one(module.lambda_auth[*].function_name)
}

output "jwt_public_key_parameter" {
  description = "Parametro SSM com a chave publica RS256 que os microsservicos usam para validar o token."
  value       = one(aws_ssm_parameter.jwt_public_key[*].name)
}

output "rds_endpoint" {
  description = "Lido do SSM publicado pelo repositorio service-track-db-infra. Nulo sem autenticacao."
  value       = one(data.aws_ssm_parameter.db_endpoint[*].value)
}

output "api_gateway_url" {
  description = "URL base publica da API, com o stage. Nula sem borda."
  value       = one(module.api_gateway[*].api_endpoint)
}

output "api_gateway_id" {
  value = one(module.api_gateway[*].api_id)
}

output "api_consumers" {
  value = one(module.api_gateway[*].consumers)
}

output "api_key_values" {
  value     = one(module.api_gateway[*].api_key_values)
  sensitive = true
}

output "api_key_ids" {
  value = one(module.api_gateway[*].api_key_ids)
}

output "jwt_authorizer_function_name" {
  value = one(module.jwt_authorizer[*].function_name)
}
