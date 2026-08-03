locals {
  src_dir = "${path.module}/src"

  src_hash = sha1(join("", [
    for f in fileset(local.src_dir, "**") : filesha1("${local.src_dir}/${f}")
  ]))
}

resource "null_resource" "build" {
  triggers = {
    src = local.src_hash
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/build.sh"
  }
}

data "archive_file" "this" {
  type        = "zip"
  source_file = "${path.module}/build/bootstrap"
  output_path = "${path.module}/build/authorizer.zip"

  depends_on = [null_resource.build]
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "this" {
  function_name = var.name
  role          = var.lab_role_arn
  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["arm64"]

  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256

  memory_size = var.memory_size
  timeout     = var.timeout

  environment {
    variables = {
      JWT_PUBLIC_KEY     = var.jwt_public_key
      JWT_ISSUER         = var.jwt_issuer
      JWT_LEEWAY_SECONDS = tostring(var.jwt_leeway_seconds)
    }
  }

  depends_on = [aws_cloudwatch_log_group.this]

  tags = var.tags

  lifecycle {
    precondition {
      condition     = trimspace(var.jwt_public_key) != ""
      error_message = "jwt_public_key vazia. Passe a chave publica RS256 em PEM (lambda_extra_env.MP_JWT_VERIFY_PUBLICKEY) ou desligue enable_jwt_authorizer."
    }
  }
}
