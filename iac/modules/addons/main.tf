locals {
  node_group_ready = var.node_group_dependency
}

resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server"
  chart            = "metrics-server"
  version          = var.metrics_server_chart_version
  namespace        = "kube-system"
  create_namespace = false

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  lifecycle {
    precondition {
      condition     = local.node_group_ready != ""
      error_message = "Node group ainda nao provisionado."
    }
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true

  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  set {
    name  = "server.service.type"
    value = var.argocd_expose_lb ? "LoadBalancer" : "ClusterIP"
  }

  timeout         = 900
  wait            = true
  cleanup_on_fail = true

  depends_on = [helm_release.metrics_server]

  lifecycle {
    precondition {
      condition     = local.node_group_ready != ""
      error_message = "Node group ainda nao provisionado."
    }
  }
}

data "kubernetes_service" "argocd_server" {
  count = var.argocd_expose_lb ? 1 : 0

  metadata {
    name      = "argocd-server"
    namespace = "argocd"
  }

  depends_on = [helm_release.argocd]
}
