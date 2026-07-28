output "namespace" {
  value = kubernetes_namespace.datadog.metadata[0].name
}

output "release_name" {
  value = helm_release.datadog.name
}

output "cluster_agent_replicas" {
  value = var.cluster_agent_replicas
}

output "endpoint_otlp_grpc" {
  description = "A aplicacao alcanca o agente pelo IP do proprio node, via hostPort."
  value       = "http://$(HOST_IP):4317"
}
