variable "name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "lambda_function_name" {
  type = string
}

variable "lambda_invoke_arn" {
  type = string
}

variable "stage_name" {
  type    = string
  default = "$default"
}
