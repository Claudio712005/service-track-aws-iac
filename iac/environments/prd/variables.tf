variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "lambda_image_tag" {
  description = "Tag da imagem da Lambda de autenticacao no ECR."
  type        = string
  default     = "latest"
}

variable "lambda_extra_env" {
  description = "Variaveis extras da Lambda (ex.: chaves JWT em PEM)."
  type        = map(string)
  default     = {}
}
