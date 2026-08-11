variable "environment" {
  type = string
}

variable "notificacao" {
  description = "Destino do alerta no formato do Datadog, por exemplo @slack-canal ou @email."
  type        = string
  default     = ""
}

variable "tags_monitor" {
  type = list(string)
}

variable "limite_latencia_p95_segundos" {
  type = number
}

variable "limite_erros_5xx" {
  description = "Quantidade de respostas 5xx em 5 minutos que dispara o alerta."
  type        = number
}

variable "limite_falhas_os" {
  description = "Erros no processamento de ordens de servico em 15 minutos."
  type        = number
}

variable "limite_falhas_integracao" {
  type = number
}

variable "minimo_de_pods" {
  description = "Replicas prontas abaixo disso indicam indisponibilidade."
  type        = number
}

variable "limite_saturacao" {
  description = "Fracao de uso de CPU do cluster que dispara o alerta."
  type        = number
}

variable "limite_uso_de_conexoes" {
  description = "Fracao do teto de conexoes do banco que dispara o alerta."
  type        = number
}

variable "habilitar_monitores_de_log" {
  description = "Monitores do tipo log alert. Exigem Log Management ativo na organizacao do Datadog; sem ele a API recusa a criacao."
  type        = bool
  default     = false
}
