output "argocd_url" {
  description = "URL do ArgoCD. HTTP, nao HTTPS: o servidor roda com server.insecure=true e o Service manda 80 e 443 para a mesma porta 8080 em texto claro. Vazio se argocd_expose_lb=false ou se o LB ainda nao tem endereco."
  value = try(
    "http://${data.kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].hostname}",
    ""
  )
}
