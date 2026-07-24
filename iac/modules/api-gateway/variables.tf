variable "name" {
  type = string
}

variable "environment" {
  description = "Nome do ambiente. Usado como nome do stage (hml | prd)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "openapi_path" {
  description = "Caminho do openApi.yaml que define a API."
  type        = string
}

variable "cors_config_path" {
  description = "Caminho do api-configuration/cors/config-<ENV>.yaml."
  type        = string
}

variable "usage_plan_config_path" {
  description = "Caminho do api-configuration/usage-plan/config-<ENV>.yaml."
  type        = string
}

variable "auth_lambda_invoke_arn" {
  description = "invoke_arn da Lambda de autenticacao (rotas /autenticacao*)."
  type        = string
}

variable "auth_lambda_function_name" {
  type = string
}

variable "app_backend_host" {
  description = "DNS do NLB interno que expoe a aplicacao no EKS."
  type        = string
}

variable "vpc_link_id" {
  description = "ID do VPC Link usado nas integracoes privadas."
  type        = string
}

variable "enable_access_logs" {
  description = <<-EOT
    Habilita access log e execution log do stage. Exige configurar a role de
    CloudWatch no nivel da conta (aws_api_gateway_account) e que essa role seja
    assumivel por apigateway.amazonaws.com. Desligue se a conta educacional nao
    permitir. Ver ADR-006.
  EOT
  type        = bool
  default     = true
}

variable "cloudwatch_role_arn" {
  description = "Role que o API Gateway assume para escrever no CloudWatch Logs."
  type        = string
  default     = null
}
