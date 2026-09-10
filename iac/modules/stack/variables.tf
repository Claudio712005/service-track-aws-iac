variable "project" {
  type    = string
  default = "servicetrack"
}

variable "environment" {
  description = "Nome do ambiente (hml ou prd)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "node_instance_types" {
  type = list(string)
}

variable "node_desired_size" {
  type = number
}

variable "node_min_size" {
  type = number
}

variable "node_max_size" {
  type = number
}

variable "argocd_chart_version" {
  type    = string
  default = "7.7.0"
}

variable "metrics_server_chart_version" {
  type    = string
  default = "3.12.2"
}

variable "argocd_expose_lb" {
  type    = bool
  default = true
}

variable "lambda_image_tag" {
  description = "Tag da imagem da Lambda no ECR. A imagem deve ser publicada antes do apply."
  type        = string
  default     = "bootstrap"
}

variable "lambda_memory_size" {
  type = number
}

variable "lambda_timeout" {
  type    = number
  default = 30
}

variable "jwt_issuer" {
  type    = string
  default = "https://servicetrack.com.br/auth"
}

variable "jwt_expiration_seconds" {
  type    = number
  default = 3600
}

variable "lambda_extra_env" {
  description = "Variaveis extras da Lambda (ex.: SMALLRYE_JWT_SIGN_KEY, MP_JWT_VERIFY_PUBLICKEY com o PEM)."
  type        = map(string)
  default     = {}
}

variable "app_node_port" {
  description = <<-EOT
    NodePort em que o Service da aplicacao e exposto no EKS. E o contrato entre
    este repositorio e os manifestos do Kubernetes: o Service precisa ser
    type=NodePort com este nodePort para o NLB do API Gateway encontrar os pods.
  EOT
  type        = number
  default     = 30080
}

variable "app_health_check_protocol" {
  description = "Health check do target group do NLB: TCP (default) ou HTTP."
  type        = string
  default     = "TCP"
}

variable "app_health_check_path" {
  description = "Rota de health check, usada apenas com app_health_check_protocol = HTTP."
  type        = string
  default     = "/"
}

variable "enable_api_access_logs" {
  description = "Habilita access/execution logs do API Gateway no CloudWatch. Ver ADR-006."
  type        = bool
  default     = true
}

variable "enable_jwt_authorizer" {
  description = <<-EOT
    Habilita o Lambda authorizer que valida o JWT na borda. Exige a chave publica
    RS256 (jwt_public_key ou lambda_extra_env.MP_JWT_VERIFY_PUBLICKEY).
    Desligado por padrao: a validacao no backend continua sendo a fonte de
    verdade. Ver ADR-007.
  EOT
  type        = bool
  default     = false
}

variable "jwt_public_key" {
  description = "Chave publica RS256 em PEM para o authorizer. Se null, usa lambda_extra_env.MP_JWT_VERIFY_PUBLICKEY."
  type        = string
  default     = null
  sensitive   = true
}

variable "jwt_leeway_seconds" {
  description = "Tolerancia de relogio na validacao de exp/nbf pelo authorizer."
  type        = number
  default     = 60
}

variable "authorizer_result_ttl_seconds" {
  description = "Cache do resultado do authorizer por token."
  type        = number
  default     = 300
}

variable "bootstrap_argocd_apps" {
  description = "Aplica o AppProject e o app-of-apps do ArgoCD no apply (GitOps). Exige kubectl e aws CLI na maquina que aplica."
  type        = bool
  default     = true
}

variable "ecr_max_image_count" {
  type    = number
  default = 10
}

variable "app_secret_params" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "state_bucket" {
  description = "Bucket do backend remoto. Usado para ler o state de rede do ambiente."
  type        = string
  default     = "servicetrack-tfstate-821146464895"
}

variable "gateway_shared_secret" {
  description = "Segredo do header x-origem-gateway. Vazio gera um automaticamente por ambiente."
  type        = string
  sensitive   = true
  default     = null
}

variable "observabilidade" {
  description = "Configuracao do Datadog por ambiente. Desabilitada nao instala agente nem cria monitores."
  type = object({
    habilitada             = bool
    api_key                = string
    app_key                = string
    site                   = string
    notificacao            = string
    cluster_agent_replicas = number
    espalhar_por_az        = bool
    coletar_logs           = bool
    coletar_traces         = bool
    recursos_node_agent = object({
      requests_cpu    = string
      requests_memory = string
      limits_cpu      = string
      limits_memory   = string
    })
    recursos_cluster_agent = object({
      requests_cpu    = string
      requests_memory = string
      limits_cpu      = string
      limits_memory   = string
    })
    limite_latencia_p95_segundos = number
    limite_erros_5xx             = number
    limite_falhas_os             = number
    limite_falhas_integracao     = number
    minimo_de_pods               = number
    limite_saturacao             = number
    limite_uso_de_conexoes       = number
  })
  sensitive = true
  default = {
    habilitada             = false
    api_key                = ""
    app_key                = ""
    site                   = "datadoghq.com"
    notificacao            = ""
    cluster_agent_replicas = 1
    espalhar_por_az        = false
    coletar_logs           = false
    coletar_traces         = false
    recursos_node_agent = {
      requests_cpu    = "100m"
      requests_memory = "256Mi"
      limits_cpu      = "500m"
      limits_memory   = "512Mi"
    }
    recursos_cluster_agent = {
      requests_cpu    = "100m"
      requests_memory = "128Mi"
      limits_cpu      = "300m"
      limits_memory   = "256Mi"
    }
    limite_latencia_p95_segundos = 2
    limite_erros_5xx             = 20
    limite_falhas_os             = 10
    limite_falhas_integracao     = 20
    minimo_de_pods               = 1
    limite_saturacao             = 0.85
    limite_uso_de_conexoes       = 0.8
  }
}

variable "unsplash_access_key" {
  description = "Chave da API do Unsplash. Segredo de terceiro, entregue pela esteira."
  type        = string
  sensitive   = true
  default     = ""
}

variable "resend_api_key" {
  description = "Chave da API do Resend, usada no envio de e-mail. Segredo de terceiro."
  type        = string
  sensitive   = true
  default     = ""
}
