variable "region" {
  description = "Regiao da AWS."
  type        = string
  default     = "us-east-1"
}

variable "ambientes" {
  description = "Ambientes que recebem um EIP reservado para o NAT Gateway."
  type        = list(string)
  default     = ["hml", "prd"]
}
