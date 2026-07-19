output "api_endpoint" {
  description = "URL base publica do HTTP API."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "api_id" {
  value = aws_apigatewayv2_api.this.id
}
