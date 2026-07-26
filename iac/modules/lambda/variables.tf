variable "name" {
  description = "Prefixo/nome base da funcao (ex.: servicetrack-prd-auth)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "image_uri" {
  description = "URI da imagem placeholder (:bootstrap) usada apenas na criacao da funcao. O codigo real e publicado depois via 'aws lambda update-function-code' (ver lifecycle.ignore_changes no main.tf)."
  type        = string
}

variable "lab_role_arn" {
  description = "ARN da role de execucao da Lambda (LabRole no ambiente educacional; ja permite VPC/ENI e logs)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "memory_size" {
  type    = number
  default = 512
}

variable "timeout" {
  type    = number
  default = 30
}

variable "db_host" {
  type = string
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type = string
}

variable "db_user" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "jwt_issuer" {
  type    = string
  default = "https://servicetrack.com.br/auth"
}

variable "jwt_expiration_seconds" {
  type    = number
  default = 3600
}

variable "extra_env" {
  description = "Variaveis de ambiente adicionais (ex.: chaves JWT em PEM). Mescladas as padrao."
  type        = map(string)
  default     = {}
}

variable "db_pool_max_size" {
  description = <<-EOT
    Conexoes maximas por container. A Lambda atende uma requisicao por container de
    cada vez, entao valor acima de 2 e desperdicio e aumenta a chance de esgotar o
    banco sob concorrencia. Orcamento definido em service-track-db-infra.
  EOT
  type        = number
  default     = 2
}
