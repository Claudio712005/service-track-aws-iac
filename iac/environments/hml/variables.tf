variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "lambda_image_tag" {
  description = "Tag da imagem da Lambda de autenticacao no ECR."
  type        = string
  default     = "bootstrap"
}

variable "lambda_extra_env" {
  description = "Variaveis extras da Lambda (ex.: chaves JWT em PEM)."
  type        = map(string)
  default     = {}
}

variable "enable_jwt_authorizer" {
  description = "Habilita o Lambda authorizer de JWT na borda. Ver ADR-007."
  type        = bool
  default     = false
}

variable "jwt_public_key" {
  description = "Chave publica RS256 em PEM para o authorizer. Se null, usa lambda_extra_env.MP_JWT_VERIFY_PUBLICKEY."
  type        = string
  default     = null
  sensitive   = true
}

variable "bootstrap_argocd_apps" {
  description = "Aplica o AppProject e o app-of-apps do ArgoCD no apply. Ver modules/stack."
  type        = bool
  default     = true
}

variable "app_secret_params" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "datadog_api_key" {
  description = "Datadog API key. Vazia desliga a observabilidade do ambiente."
  type        = string
  sensitive   = true
  default     = ""
}

variable "datadog_app_key" {
  description = "Datadog application key. Necessaria para criar dashboards e monitores."
  type        = string
  sensitive   = true
  default     = ""
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.com"
}

variable "datadog_notificacao" {
  description = "Destino dos alertas no formato do Datadog, por exemplo @slack-canal."
  type        = string
  default     = ""
}
