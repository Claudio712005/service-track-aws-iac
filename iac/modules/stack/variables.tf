variable "project" {
  type    = string
  default = "servicetrack"
}

variable "environment" {
  description = "Nome do ambiente (hml ou prd)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
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

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "node_instance_types" {
  type = list(string)
}

variable "node_desired_size" {
  type = number
}

variable "node_min_size" {
  type = number
}

variable "node_max_size" {
  type = number
}

variable "argocd_chart_version" {
  type    = string
  default = "7.7.0"
}

variable "metrics_server_chart_version" {
  type    = string
  default = "3.12.2"
}

variable "argocd_expose_lb" {
  type    = bool
  default = true
}

variable "db_name" {
  type    = string
  default = "servicetrack"
}

variable "db_username" {
  type    = string
  default = "servicetrack"
}

variable "db_instance_class" {
  type = string
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_engine_version" {
  type    = string
  default = "16.9"
}

variable "lambda_image_tag" {
  description = "Tag da imagem da Lambda no ECR. A imagem deve ser publicada antes do apply."
  type        = string
  default     = "bootstrap"
}

variable "lambda_memory_size" {
  type = number
}

variable "lambda_timeout" {
  type    = number
  default = 30
}

variable "jwt_issuer" {
  type    = string
  default = "https://servicetrack.com.br/auth"
}

variable "jwt_expiration_seconds" {
  type    = number
  default = 3600
}

variable "lambda_extra_env" {
  description = "Variaveis extras da Lambda (ex.: SMALLRYE_JWT_SIGN_KEY, MP_JWT_VERIFY_PUBLICKEY com o PEM)."
  type        = map(string)
  default     = {}
}
