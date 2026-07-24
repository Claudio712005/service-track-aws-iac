locals {
  cors = yamldecode(file(var.cors_config_path))["cors"]
  plan = yamldecode(file(var.usage_plan_config_path))

  cors_response_headers = merge(
    {
      "method.response.header.Access-Control-Allow-Origin"  = "'${local.cors.allowOrigin}'"
      "method.response.header.Access-Control-Allow-Methods" = "'${local.cors.allowMethods}'"
      "method.response.header.Access-Control-Allow-Headers" = "'${local.cors.allowHeaders}'"
      "method.response.header.Access-Control-Max-Age"       = "'${local.cors.maxAge}'"
    },
    local.cors.allowCredentials ? {
      "method.response.header.Access-Control-Allow-Credentials" = "'true'"
    } : {}
  )

  cors_declared_headers = merge(
    {
      "Access-Control-Allow-Origin"  = { schema = { type = "string" } }
      "Access-Control-Allow-Methods" = { schema = { type = "string" } }
      "Access-Control-Allow-Headers" = { schema = { type = "string" } }
      "Access-Control-Max-Age"       = { schema = { type = "string" } }
    },
    local.cors.allowCredentials ? {
      "Access-Control-Allow-Credentials" = { schema = { type = "string" } }
    } : {}
  )

  cors_options = jsonencode({
    security = []
    responses = {
      "200" = {
        description = "CORS preflight"
        headers     = local.cors_declared_headers
      }
    }
    "x-amazon-apigateway-integration" = {
      type                = "mock"
      requestTemplates    = { "application/json" = "{\"statusCode\": 200}" }
      passthroughBehavior = "when_no_match"
      responses = {
        default = {
          statusCode         = "200"
          responseParameters = local.cors_response_headers
        }
      }
    }
  })

  body = templatefile(var.openapi_path, {
    auth_lambda_uri  = var.auth_lambda_invoke_arn
    app_backend_host = var.app_backend_host
    vpc_link_id      = var.vpc_link_id
    cors_options     = local.cors_options
  })

  stage_cfg = local.plan["stage"]
}

resource "aws_api_gateway_rest_api" "this" {
  name        = "${var.name}-api"
  description = "Service Track API - definida por apis/service-track-api-ext/openApi.yaml"
  body        = local.body

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  fail_on_warnings = false

  tags = var.tags
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(local.body)
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_account" "this" {
  count = var.enable_access_logs ? 1 : 0

  cloudwatch_role_arn = var.cloudwatch_role_arn
}

resource "aws_cloudwatch_log_group" "access" {
  count = var.enable_access_logs ? 1 : 0

  name              = "/aws/apigateway/${var.name}-api/${var.environment}"
  retention_in_days = local.stage_cfg["accessLogRetentionDays"]
  tags              = var.tags
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.environment

  dynamic "access_log_settings" {
    for_each = var.enable_access_logs ? [1] : []

    content {
      destination_arn = aws_cloudwatch_log_group.access[0].arn
      format = jsonencode({
        requestId      = "$context.requestId"
        ip             = "$context.identity.sourceIp"
        requestTime    = "$context.requestTime"
        httpMethod     = "$context.httpMethod"
        path           = "$context.path"
        status         = "$context.status"
        protocol       = "$context.protocol"
        responseLength = "$context.responseLength"
        integrationErr = "$context.integration.error"
        apiKeyId       = "$context.identity.apiKeyId"
      })
    }
  }

  tags = var.tags

  depends_on = [aws_api_gateway_account.this]
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = local.stage_cfg["throttle"]["rateLimit"]
    throttling_burst_limit = local.stage_cfg["throttle"]["burstLimit"]

    metrics_enabled = local.stage_cfg["detailedMetrics"]

    logging_level      = var.enable_access_logs ? local.stage_cfg["loggingLevel"] : "OFF"
    data_trace_enabled = var.enable_access_logs ? local.stage_cfg["dataTrace"] : false
  }
}

resource "aws_api_gateway_api_key" "this" {
  name        = "${var.name}-key"
  description = "API key do ambiente ${var.environment}"
  enabled     = true
  tags        = var.tags
}

resource "aws_api_gateway_usage_plan" "this" {
  name        = "${var.name}-usage-plan"
  description = "Throttling e quota do ambiente ${var.environment}"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    rate_limit  = local.plan["usagePlan"]["throttle"]["rateLimit"]
    burst_limit = local.plan["usagePlan"]["throttle"]["burstLimit"]
  }

  quota_settings {
    limit  = local.plan["usagePlan"]["quota"]["limit"]
    period = local.plan["usagePlan"]["quota"]["period"]
  }

  tags = var.tags
}

resource "aws_api_gateway_usage_plan_key" "this" {
  key_id        = aws_api_gateway_api_key.this.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.this.id
}

resource "aws_api_gateway_gateway_response" "cors_4xx" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  response_type = "DEFAULT_4XX"

  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'${local.cors.allowOrigin}'"
    "gatewayresponse.header.Access-Control-Allow-Methods" = "'${local.cors.allowMethods}'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'${local.cors.allowHeaders}'"
  }
}

resource "aws_api_gateway_gateway_response" "cors_5xx" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  response_type = "DEFAULT_5XX"

  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'${local.cors.allowOrigin}'"
    "gatewayresponse.header.Access-Control-Allow-Methods" = "'${local.cors.allowMethods}'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'${local.cors.allowHeaders}'"
  }
}

resource "aws_lambda_permission" "auth" {
  statement_id  = "AllowInvokeFromApiGateway-${var.environment}"
  action        = "lambda:InvokeFunction"
  function_name = var.auth_lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*/*"
}
