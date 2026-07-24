output "api_endpoint" {
  description = "URL base publica da API (inclui o stage)."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "api_id" {
  value = aws_api_gateway_rest_api.this.id
}

output "stage_name" {
  value = aws_api_gateway_stage.this.stage_name
}

output "api_key_id" {
  value = aws_api_gateway_api_key.this.id
}

output "api_key_value" {
  description = "Valor da API key. Enviar no header x-api-key. Muda a cada recriacao."
  value       = aws_api_gateway_api_key.this.value
  sensitive   = true
}

output "usage_plan_id" {
  value = aws_api_gateway_usage_plan.this.id
}
