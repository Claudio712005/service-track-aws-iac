locals {
  state_bucket = var.state_bucket != "" ? var.state_bucket : "servicetrack-tfstate-${data.aws_caller_identity.atual.account_id}"

  name         = "${var.project}-${var.environment}"
  cluster_name = "${var.project}-${var.environment}"

  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })

  autenticacao = var.habilitar_autenticacao ? 1 : 0
  borda        = var.habilitar_borda ? 1 : 0

  api_ext_dir = "${path.module}/../../../apis/service-track-api-ext"
  env_suffix  = upper(var.environment)

  jwt_private_key_pem = one(tls_private_key.jwt[*].private_key_pem_pkcs8)
  jwt_public_key_pem  = one(tls_private_key.jwt[*].public_key_pem)

  jwt_public_key = coalesce(var.jwt_public_key, local.jwt_public_key_pem)

  lambda_env = merge(
    {
      MP_JWT_VERIFY_PUBLICKEY = local.jwt_public_key_pem
      SMALLRYE_JWT_SIGN_KEY   = local.jwt_private_key_pem
    },
    var.lambda_extra_env,
  )

  argocd_bootstrap_files = [
    "${path.module}/../../../kubernetes/argocd/projects/service-track.appproject.yaml",
    "${path.module}/../../../kubernetes/argocd/templates/application.yaml",
    "${path.module}/../../../scripts/argocd-bootstrap-apply.sh",
  ]
}

data "aws_region" "current" {}

data "aws_caller_identity" "atual" {}

data "aws_iam_role" "lab" {
  name = "LabRole"
}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = local.state_bucket
    key    = "servicetrack/${var.environment}-network/terraform.tfstate"
    region = data.aws_region.current.name
  }
}

locals {
  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
  public_subnet_ids  = data.terraform_remote_state.network.outputs.public_subnet_ids
}

module "eks" {
  source = "../eks"

  name                = local.name
  tags                = local.tags
  cluster_name        = local.cluster_name
  cluster_version     = var.cluster_version
  public_subnet_ids   = local.public_subnet_ids
  private_subnet_ids  = local.private_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  lab_role_arn        = data.aws_iam_role.lab.arn
}

module "addons" {
  source = "../addons"

  argocd_chart_version         = var.argocd_chart_version
  metrics_server_chart_version = var.metrics_server_chart_version
  argocd_expose_lb             = var.argocd_expose_lb
  node_group_dependency        = module.eks.node_group
}

resource "null_resource" "argocd_bootstrap" {
  count = var.bootstrap_argocd_apps ? 1 : 0

  triggers = {
    manifests  = join(",", [for f in local.argocd_bootstrap_files : filesha1(f)])
    cluster    = module.eks.cluster_name
    descoberta = timestamp()
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/../../../scripts/argocd-bootstrap-apply.sh ${module.eks.cluster_name} ${data.aws_region.current.name} ${var.environment}"
  }

  depends_on = [module.addons]
}

data "aws_ssm_parameter" "db_endpoint" {
  count = local.autenticacao
  name  = "/${var.project}/${var.environment}/db/endpoint"
}

data "aws_ssm_parameter" "db_port" {
  count = local.autenticacao
  name  = "/${var.project}/${var.environment}/db/port"
}

data "aws_ssm_parameter" "db_name" {
  count = local.autenticacao
  name  = "/${var.project}/${var.environment}/db/name"
}

data "aws_ssm_parameter" "db_username" {
  count = local.autenticacao
  name  = "/${var.project}/${var.environment}/db/username"
}

data "aws_ssm_parameter" "db_password" {
  count           = local.autenticacao
  name            = "/${var.project}/${var.environment}/db/password"
  with_decryption = true
}

data "aws_ssm_parameter" "db_security_group_id" {
  count = local.autenticacao
  name  = "/${var.project}/${var.environment}/db/security-group-id"
}

data "aws_ssm_parameter" "pool_lambda_max_size" {
  count = local.autenticacao
  name  = "/${var.project}/${var.environment}/db/pool/lambda-max-size"
}

resource "tls_private_key" "jwt" {
  count = local.autenticacao

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_ssm_parameter" "jwt_public_key" {
  count = local.autenticacao

  name  = "/${var.project}/${var.environment}/jwt-public"
  type  = "String"
  value = local.jwt_public_key_pem
  tags  = local.tags
}

module "ecr_lambda" {
  source = "../ecr"
  count  = local.autenticacao

  repository_name      = "${local.name}-auth-lambda"
  image_tag_mutability = "MUTABLE"
  max_image_count      = var.ecr_max_image_count
  tags                 = local.tags
}

module "lambda_auth" {
  source = "../lambda"
  count  = local.autenticacao

  name               = "${local.name}-auth"
  tags               = local.tags
  image_uri          = "${module.ecr_lambda[0].repository_url}:${var.lambda_image_tag}"
  lab_role_arn       = data.aws_iam_role.lab.arn
  vpc_id             = local.vpc_id
  private_subnet_ids = local.private_subnet_ids
  memory_size        = var.lambda_memory_size
  timeout            = var.lambda_timeout

  db_host     = nonsensitive(data.aws_ssm_parameter.db_endpoint[0].value)
  db_port     = nonsensitive(data.aws_ssm_parameter.db_port[0].value)
  db_name     = nonsensitive(data.aws_ssm_parameter.db_name[0].value)
  db_user     = data.aws_ssm_parameter.db_username[0].value
  db_password = data.aws_ssm_parameter.db_password[0].value

  db_pool_max_size = tonumber(data.aws_ssm_parameter.pool_lambda_max_size[0].value)

  jwt_issuer             = var.jwt_issuer
  jwt_expiration_seconds = var.jwt_expiration_seconds
  extra_env              = local.lambda_env
}

resource "aws_security_group_rule" "rds_from_lambda" {
  count = local.autenticacao

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  description              = "PostgreSQL a partir da Lambda de autenticacao"
  security_group_id        = data.aws_ssm_parameter.db_security_group_id[0].value
  source_security_group_id = module.lambda_auth[0].security_group_id
}

module "jwt_authorizer" {
  source = "../lambda-authorizer"
  count  = var.habilitar_borda && var.enable_jwt_authorizer ? 1 : 0

  name               = "${local.name}-jwt-authorizer"
  tags               = local.tags
  lab_role_arn       = data.aws_iam_role.lab.arn
  jwt_public_key     = local.jwt_public_key
  jwt_issuer         = var.jwt_issuer
  jwt_leeway_seconds = var.jwt_leeway_seconds
}

module "api_gateway" {
  source = "../api-gateway"
  count  = local.borda

  name        = local.name
  environment = var.environment
  tags        = local.tags

  openapi_path           = "${local.api_ext_dir}/openApi.yaml"
  cors_config_path       = "${local.api_ext_dir}/api-configuration/cors/config-${local.env_suffix}.yaml"
  usage_plan_config_path = "${local.api_ext_dir}/api-configuration/usage-plan/config-${local.env_suffix}.yaml"

  auth_lambda_function_name = module.lambda_auth[0].function_name
  auth_lambda_invoke_arn    = module.lambda_auth[0].invoke_arn

  authorizer_invoke_arn         = var.enable_jwt_authorizer ? module.jwt_authorizer[0].invoke_arn : null
  authorizer_function_name      = var.enable_jwt_authorizer ? module.jwt_authorizer[0].function_name : null
  authorizer_result_ttl_seconds = var.authorizer_result_ttl_seconds

  enable_access_logs  = var.enable_api_access_logs
  cloudwatch_role_arn = data.aws_iam_role.lab.arn
}

resource "aws_ssm_parameter" "api_base_url" {
  count = local.borda

  name  = "/${var.project}/${var.environment}/api/base-url"
  type  = "String"
  value = module.api_gateway[0].api_endpoint
  tags  = local.tags
}
