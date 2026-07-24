variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "registered_domain" {
  description = "Dominio registrado no Registro.br, sem subdominio. Ex.: clausilva.com.br"
  type        = string
}

variable "subdomain" {
  description = "Label delegado ao Route53 dentro do dominio registrado. Ex.: api"
  type        = string
  default     = "api"

  validation {
    condition     = length(trimspace(var.subdomain)) > 0 && !strcontains(var.subdomain, ".")
    error_message = "subdomain deve ser um unico label, sem pontos."
  }
}
