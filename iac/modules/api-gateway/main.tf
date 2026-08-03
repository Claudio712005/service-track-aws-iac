locals {
  cors = yamldecode(file(var.cors_config_path))["cors"]
  plan = yamldecode(file(var.usage_plan_config_path))

  waf         = try(local.plan["waf"], { enabled = false })
  waf_enabled = try(local.waf["enabled"], false)

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

  bearer_auth_scheme = var.authorizer_invoke_arn == null ? jsonencode({
    type         = "http"
    scheme       = "bearer"
    bearerFormat = "JWT"
    }) : jsonencode({
    type                           = "apiKey"
    name                           = "Authorization"
    in                             = "header"
    "x-amazon-apigateway-authtype" = "custom"
    "x-amazon-apigateway-authorizer" = {
      type                         = "token"
      authorizerUri                = var.authorizer_invoke_arn
      authorizerResultTtlInSeconds = var.authorizer_result_ttl_seconds
      identityValidationExpression = "^[Bb]earer [-_.A-Za-z0-9]+$"
    }
  })

  body = templatefile(var.openapi_path, {
    auth_lambda_uri       = var.auth_lambda_invoke_arn
    app_backend_host      = var.app_backend_host
    vpc_link_id           = var.vpc_link_id
    cors_options          = local.cors_options
    bearer_auth_scheme    = local.bearer_auth_scheme
    gateway_shared_secret = var.gateway_shared_secret
  })

  stage_cfg = local.plan["stage"]

  consumers = {
    for name, cfg in try(local.plan["consumers"], {}) : name => cfg
    if try(cfg["enabled"], true)
  }

  dedicated_consumers = {
    for name, cfg in local.consumers : name => cfg
    if lookup(cfg, "throttle", null) != null || lookup(cfg, "quota", null) != null
  }

  shared_consumers = {
    for name, cfg in local.consumers : name => cfg
    if !contains(keys(local.dedicated_consumers), name)
  }

  domain             = var.custom_domain
  create_domain      = var.custom_domain != null
  create_certificate = var.custom_domain != null && try(var.custom_domain.certificate_arn, null) == null

  lookup_zone = (
    var.custom_domain != null &&
    try(var.custom_domain.hosted_zone_name, null) != null &&
    try(var.custom_domain.hosted_zone_id, null) == null
  )

  create_dns = var.custom_domain != null && (
    try(var.custom_domain.hosted_zone_id, null) != null ||
    try(var.custom_domain.hosted_zone_name, null) != null
  )

  zone_id = local.lookup_zone ? try(data.aws_route53_zone.this[0].zone_id, null) : try(var.custom_domain.hosted_zone_id, null)
}

data "aws_route53_zone" "this" {
  count = local.lookup_zone ? 1 : 0

  name         = var.custom_domain.hosted_zone_name
  private_zone = false
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
        authorizerErr  = "$context.authorizer.error"
        principalId    = "$context.authorizer.principalId"
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

resource "aws_api_gateway_api_key" "consumer" {
  for_each = local.consumers

  name        = "${var.name}-${each.key}"
  description = try(each.value["description"], "Consumidor ${each.key} (${var.environment})")
  enabled     = true
  tags        = merge(var.tags, { Consumer = each.key })
}

resource "aws_api_gateway_usage_plan" "default" {
  name        = "${var.name}-usage-plan"
  description = "Throttling e quota padrao do ambiente ${var.environment}"

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

resource "aws_api_gateway_usage_plan" "dedicated" {
  for_each = local.dedicated_consumers

  name        = "${var.name}-${each.key}-usage-plan"
  description = "Limites dedicados do consumidor ${each.key} (${var.environment})"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    rate_limit  = try(each.value["throttle"]["rateLimit"], local.plan["usagePlan"]["throttle"]["rateLimit"])
    burst_limit = try(each.value["throttle"]["burstLimit"], local.plan["usagePlan"]["throttle"]["burstLimit"])
  }

  quota_settings {
    limit  = try(each.value["quota"]["limit"], local.plan["usagePlan"]["quota"]["limit"])
    period = try(each.value["quota"]["period"], local.plan["usagePlan"]["quota"]["period"])
  }

  tags = merge(var.tags, { Consumer = each.key })
}

resource "aws_api_gateway_usage_plan_key" "shared" {
  for_each = local.shared_consumers

  key_id        = aws_api_gateway_api_key.consumer[each.key].id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.default.id
}

resource "aws_api_gateway_usage_plan_key" "dedicated" {
  for_each = local.dedicated_consumers

  key_id        = aws_api_gateway_api_key.consumer[each.key].id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.dedicated[each.key].id
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

resource "aws_lambda_permission" "authorizer" {
  count = var.authorizer_invoke_arn == null ? 0 : 1

  statement_id  = "AllowInvokeAuthorizerFromApiGateway-${var.environment}"
  action        = "lambda:InvokeFunction"
  function_name = var.authorizer_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/authorizers/*"
}

resource "aws_acm_certificate" "this" {
  count = local.create_certificate ? 1 : 0

  domain_name       = local.domain.domain_name
  validation_method = "DNS"

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.create_certificate && local.create_dns ? {
    for opt in aws_acm_certificate.this[0].domain_validation_options :
    opt.domain_name => opt
  } : {}

  zone_id         = local.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = local.create_certificate ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_api_gateway_domain_name" "this" {
  count = local.create_domain ? 1 : 0

  domain_name = local.domain.domain_name
  regional_certificate_arn = (
    local.create_certificate
    ? aws_acm_certificate_validation.this[0].certificate_arn
    : local.domain.certificate_arn
  )
  security_policy = "TLS_1_2"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.tags
}

resource "aws_api_gateway_base_path_mapping" "this" {
  count = local.create_domain ? 1 : 0

  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  domain_name = aws_api_gateway_domain_name.this[0].domain_name
  base_path   = local.domain.base_path
}

resource "aws_route53_record" "api" {
  count = local.create_dns ? 1 : 0

  zone_id = local.zone_id
  name    = local.domain.domain_name
  type    = "A"

  alias {
    name                   = aws_api_gateway_domain_name.this[0].regional_domain_name
    zone_id                = aws_api_gateway_domain_name.this[0].regional_zone_id
    evaluate_target_health = false
  }
}

resource "aws_wafv2_web_acl" "this" {
  count = local.waf_enabled ? 1 : 0

  name        = "${var.name}-${var.environment}-waf"
  description = "Rate limiting por IP na borda do API Gateway (${var.environment})"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-por-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = try(local.waf["rateLimit"], 2000)
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-${var.environment}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-${var.environment}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

resource "aws_wafv2_web_acl_association" "this" {
  count = local.waf_enabled ? 1 : 0

  resource_arn = aws_api_gateway_stage.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}
