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
  description = "Cria a Lambda de autenticacao, o ECR dela e o par RS256. Ligada por padrao (IAC-ADR-036): a autenticacao e passo normal da subida. Depende do service-track-usuarios-veiculos de pe, que e quem confere a credencial."
  type        = bool
  default     = true
}

variable "habilitar_borda" {
  description = "Cria o API Gateway publico. Ligada por padrao (IAC-ADR-036): e por ela que POST /autenticacao e /bff ficam alcancaveis. Exige habilitar_autenticacao."
  type        = bool
  default     = true
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

variable "habilitar_entrada_do_bff" {
  description = "Cria o NLB interno e o VPC Link. Ligada por padrao (IAC-ADR-036): e o caminho da borda ate o BFF e da Lambda ate a verificacao de credencial. Exigida por habilitar_autenticacao."
  type        = bool
  default     = true
}
