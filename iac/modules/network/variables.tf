variable "name" {
  description = "Prefixo de nomes dos recursos (ex.: servicetrack-prd)."
  type        = string
}

variable "tags" {
  description = "Tags aplicadas a todos os recursos."
  type        = map(string)
  default     = {}
}

variable "cluster_name" {
  description = "Nome do cluster EKS, usado nas tags de descoberta das subnets."
  type        = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}
