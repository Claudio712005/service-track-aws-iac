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

variable "enable_custom_domain" {
  description = <<-EOT
    Publica a API em api.clausilva.com.br. Exige a hosted zone criada por
    iac/bootstrap/dns E a delegacao NS ja ativa no Registro.br -- sem ela a
    validacao do certificado ACM fica pendurada ate estourar o timeout.
    A esteira dns-publish.yml verifica a delegacao antes de ligar.
  EOT
  type        = bool
  default     = false
}

variable "api_domain_name" {
  description = "Dominio publico da API em PRD."
  type        = string
  default     = "api.clausilva.com.br"
}

variable "api_hosted_zone_name" {
  description = "Hosted zone Route53 persistente que serve o dominio."
  type        = string
  default     = "api.clausilva.com.br"
}

variable "api_base_path" {
  type    = string
  default = "service-track/v1"
}

variable "bootstrap_argocd_apps" {
  description = "Aplica o AppProject e o app-of-apps do ArgoCD no apply. Ver modules/stack."
  type        = bool
  default     = true
}
