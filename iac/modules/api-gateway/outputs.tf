output "api_endpoint" {
  description = "URL base publica da API pelo endpoint execute-api (inclui o stage)."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "api_id" {
  value = aws_api_gateway_rest_api.this.id
}

output "stage_name" {
  value = aws_api_gateway_stage.this.stage_name
}

output "consumers" {
  description = "Consumidores habilitados, cada um com sua API key."
  value       = sort(keys(local.consumers))
}

output "api_key_values" {
  description = "Valor da API key por consumidor. Enviar no header x-api-key."
  value       = { for name, key in aws_api_gateway_api_key.consumer : name => key.value }
  sensitive   = true
}

output "api_key_ids" {
  value = { for name, key in aws_api_gateway_api_key.consumer : name => key.id }
}

output "usage_plan_id" {
  description = "Usage plan padrao do ambiente."
  value       = aws_api_gateway_usage_plan.default.id
}

output "dedicated_usage_plan_ids" {
  description = "Usage plans dedicados, por consumidor que declarou limites proprios."
  value       = { for name, plan in aws_api_gateway_usage_plan.dedicated : name => plan.id }
}

output "custom_domain_url" {
  description = "URL pela qual a API responde no dominio customizado, se habilitado."
  value = (
    local.create_domain
    ? "https://${aws_api_gateway_domain_name.this[0].domain_name}/${local.domain.base_path}"
    : null
  )
}

output "custom_domain_target" {
  description = "Alvo regional do dominio, para apontar o DNS manualmente quando hosted_zone_id nao e informado."
  value = (
    local.create_domain
    ? aws_api_gateway_domain_name.this[0].regional_domain_name
    : null
  )
}
