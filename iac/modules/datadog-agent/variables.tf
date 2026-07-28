variable "name" {
  type = string
}

variable "environment" {
  type = string
}

variable "namespace" {
  type    = string
  default = "datadog"
}

variable "chart_version" {
  type    = string
  default = "3.70.4"
}

variable "api_key" {
  description = "Datadog API key. Ingestao de metricas, traces e logs."
  type        = string
  sensitive   = true
}

variable "app_key" {
  description = "Datadog application key. Necessaria para o cluster agent registrar o cluster."
  type        = string
  sensitive   = true
  default     = ""
}

variable "site" {
  type    = string
  default = "datadoghq.com"
}

variable "cluster_name" {
  type = string
}

variable "cluster_agent_replicas" {
  description = "Replicas do cluster agent. Duas exigem pelo menos dois nodes para espalhar por AZ."
  type        = number
}

variable "espalhar_por_az" {
  description = "Distribui as replicas do cluster agent entre zonas. So faz sentido com mais de uma replica."
  type        = bool
}

variable "coletar_logs" {
  type = bool
}

variable "coletar_traces" {
  type = bool
}

variable "recursos_node_agent" {
  type = object({
    requests_cpu    = string
    requests_memory = string
    limits_cpu      = string
    limits_memory   = string
  })
}

variable "recursos_cluster_agent" {
  type = object({
    requests_cpu    = string
    requests_memory = string
    limits_cpu      = string
    limits_memory   = string
  })
}

variable "depends_on_node_group" {
  description = "Amarra a instalacao ao node group, para o Helm nao rodar antes de existir node."
  type        = any
  default     = null
}
