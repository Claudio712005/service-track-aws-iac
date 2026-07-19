output "argocd_url" {
  description = "URL do ArgoCD (vazio se argocd_expose_lb=false ou LB ainda provisionando)."
  value = try(
    "https://${data.kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].hostname}",
    ""
  )
}
