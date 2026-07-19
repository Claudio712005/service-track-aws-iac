variable "argocd_chart_version" {
  type = string
}

variable "metrics_server_chart_version" {
  type = string
}

variable "argocd_expose_lb" {
  description = "Expor o argocd-server via LoadBalancer publico. false = acesso apenas por kubectl port-forward."
  type        = bool
  default     = true
}

variable "node_group_dependency" {
  description = "Valor do node group para forcar ordem: addons so instalam apos os nodes existirem."
  type        = string
}
