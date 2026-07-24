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

# HML nao expoe dominio customizado por decisao: o dominio clausilva.com.br fica
# reservado para PRD e o orcamento de HML foi realocado para observabilidade.
# Sem a variavel, ligar o dominio em HML exige mudanca de codigo revisavel.
