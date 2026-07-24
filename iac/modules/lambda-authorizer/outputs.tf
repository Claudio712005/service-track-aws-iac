output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "invoke_arn" {
  description = "URI de invocacao usada em x-amazon-apigateway-authorizer.authorizerUri."
  value       = aws_lambda_function.this.invoke_arn
}
