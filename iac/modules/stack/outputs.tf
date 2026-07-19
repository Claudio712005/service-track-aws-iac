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
  value = module.rds.address
}

output "rds_jdbc_url" {
  value = module.rds.jdbc_url
}

output "db_username" {
  value = module.rds.username
}

output "db_password" {
  value     = module.rds.password
  sensitive = true
}

output "lambda_function_name" {
  value = module.lambda_auth.function_name
}

output "api_gateway_url" {
  description = "URL publica do endpoint de autenticacao (ex.: <url>/autenticacao/login)."
  value       = module.api_gateway.api_endpoint
}

output "argocd_url" {
  value = module.addons.argocd_url
}

output "argocd_admin_password_cmd" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

data "aws_region" "current" {}
