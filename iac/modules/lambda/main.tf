resource "aws_security_group" "lambda" {
  name        = "${var.name}-lambda-sg"
  description = "Egress da Lambda ${var.name} para RDS e internet"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-lambda-sg" })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_lambda_function" "this" {
  function_name = var.name
  role          = var.lab_role_arn
  package_type  = "Image"
  image_uri     = var.image_uri
  memory_size   = var.memory_size
  timeout       = var.timeout

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = merge({
      POSTGRES_HOST     = var.db_host
      POSTGRES_PORT     = tostring(var.db_port)
      POSTGRES_DB       = var.db_name
      POSTGRES_USER     = var.db_user
      POSTGRES_PASSWORD = var.db_password

      MP_JWT_VERIFY_ISSUER                = var.jwt_issuer
      SERVICETRACK_JWT_EXPIRACAO_SEGUNDOS = tostring(var.jwt_expiration_seconds)
    }, var.extra_env)
  }

  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = var.tags

  lifecycle {
    ignore_changes = [image_uri]
  }
}
