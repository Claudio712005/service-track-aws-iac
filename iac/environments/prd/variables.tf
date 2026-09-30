variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "argocd_expose_lb" {
  description = "Expor o argocd-server por LoadBalancer. Escolhido por execucao da esteira; sem escolha vale o padrao deste ambiente."
  type        = bool
  default     = true
}

variable "habilitar_autenticacao" {
  description = "Cria a Lambda de autenticacao e a leitura do banco. Desligada ate a modelagem de dados da Fase 4 fechar."
  type        = bool
  default     = false
}

variable "habilitar_borda" {
  description = "Cria o API Gateway. Exige habilitar_autenticacao. Desligada: os microsservicos nao sao alcancaveis de fora do cluster."
  type        = bool
  default     = false
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
  description = "Aplica o AppProject e gera as Applications dos microsservicos descobertos. Ver modules/stack."
  type        = bool
  default     = true
}
