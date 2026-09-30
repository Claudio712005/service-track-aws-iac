output "argocd_url" {
  description = "URL do ArgoCD. HTTPS com certificado autoassinado do proprio servidor (IAC-ADR-031): o navegador avisa. Vazio se argocd_expose_lb=false ou se o LB ainda nao tem endereco."
  value = try(
    "http://${data.kubernetes_service.argocd_server[0].status[0].load_balancer[0].ingress[0].hostname}",
    ""
  )
}
