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

variable "authorizer_invoke_arn" {
  description = <<-EOT
    invoke_arn do Lambda authorizer de JWT. Quando null, o securityScheme
    bearerAuth fica como http/bearer (ignorado pelo gateway) e a validacao do
    JWT ocorre apenas no backend. Ver ADR-007.
  EOT
  type        = string
  default     = null
}

variable "authorizer_function_name" {
  description = "Nome da funcao do authorizer, para a permissao de invocacao."
  type        = string
  default     = null
}

variable "authorizer_result_ttl_seconds" {
  description = "Cache do resultado do authorizer por token. 0 desliga o cache."
  type        = number
  default     = 300
}

variable "gateway_shared_secret" {
  description = "Segredo injetado pelo gateway no header x-origem-gateway. A aplicacao recusa requisicao sem ele."
  type        = string
  sensitive   = true
}
