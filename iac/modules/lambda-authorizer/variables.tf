variable "name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "lab_role_arn" {
  type = string
}

variable "jwt_public_key" {
  description = "Chave publica RS256 em PEM usada para verificar a assinatura do JWT."
  type        = string
  sensitive   = true
}

variable "jwt_issuer" {
  description = "Emissor esperado no claim iss. Vazio desliga a checagem."
  type        = string
  default     = ""
}

variable "jwt_leeway_seconds" {
  description = "Tolerancia de relogio na validacao de exp/nbf."
  type        = number
  default     = 60
}

variable "memory_size" {
  type    = number
  default = 256
}

variable "timeout" {
  type    = number
  default = 5
}

variable "log_retention_days" {
  type    = number
  default = 14
}
