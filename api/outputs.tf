output "region" {
  value = var.aws_region
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.aws_region}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "rds_endpoint" {
  value = aws_db_instance.this.address
}

output "rds_jdbc_url" {
  value = "jdbc:postgresql://${aws_db_instance.this.address}:${aws_db_instance.this.port}/${var.db_name}"
}

output "db_username" {
  value = var.db_username
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}

output "argocd_url" {
  description = "URL do ArgoCD (vazio se argocd_expose_lb=false ou LB ainda provisionando)."
  value = try(
    "https://${data.kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].hostname}",
    ""
  )
}

output "argocd_admin_password_cmd" {
  description = "Comando para obter a senha inicial do admin do ArgoCD."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}
