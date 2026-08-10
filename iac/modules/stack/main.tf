resource "random_password" "gateway_shared_secret" {
  length  = 48
  special = false
}

resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

locals {
  gateway_shared_secret = coalesce(var.gateway_shared_secret, random_password.gateway_shared_secret.result)

  name         = "${var.project}-${var.environment}"
  cluster_name = "${var.project}-${var.environment}"

  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })

  api_ext_dir = "${path.module}/../../../apis/service-track-api-ext"
  env_suffix  = upper(var.environment)

  jwt_private_key_pem = tls_private_key.jwt.private_key_pem_pkcs8
  jwt_public_key_pem  = tls_private_key.jwt.public_key_pem

  jwt_public_key = coalesce(var.jwt_public_key, local.jwt_public_key_pem)

  lambda_env = merge(
    {
      MP_JWT_VERIFY_PUBLICKEY = local.jwt_public_key_pem
      SMALLRYE_JWT_SIGN_KEY   = local.jwt_private_key_pem
    },
    var.lambda_extra_env,
  )
}

data "aws_iam_role" "lab" {
  name = "LabRole"
}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "servicetrack/${var.environment}-network/terraform.tfstate"
    region = data.aws_region.current.name
  }
}

data "aws_ssm_parameter" "db_endpoint" {
  name = "/${var.project}/${var.environment}/db/endpoint"
}

data "aws_ssm_parameter" "db_port" {
  name = "/${var.project}/${var.environment}/db/port"
}

data "aws_ssm_parameter" "db_name" {
  name = "/${var.project}/${var.environment}/db/name"
}

data "aws_ssm_parameter" "db_username" {
  name = "/${var.project}/${var.environment}/db/username"
}

data "aws_ssm_parameter" "db_password" {
  name            = "/${var.project}/${var.environment}/db/password"
  with_decryption = true
}

data "aws_ssm_parameter" "db_security_group_id" {
  name = "/${var.project}/${var.environment}/db/security-group-id"
}

data "aws_ssm_parameter" "pool_api_max_size" {
  name = "/${var.project}/${var.environment}/db/pool/api-max-size"
}

data "aws_ssm_parameter" "pool_api_migration_max_size" {
  name = "/${var.project}/${var.environment}/db/pool/api-migration-max-size"
}

data "aws_ssm_parameter" "pool_lambda_max_size" {
  name = "/${var.project}/${var.environment}/db/pool/lambda-max-size"
}

locals {
  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
  public_subnet_ids  = data.terraform_remote_state.network.outputs.public_subnet_ids
  vpc_cidr           = data.terraform_remote_state.network.outputs.vpc_cidr

  db_endpoint = data.aws_ssm_parameter.db_endpoint.value
  db_port     = data.aws_ssm_parameter.db_port.value
  db_name     = data.aws_ssm_parameter.db_name.value
  db_username = data.aws_ssm_parameter.db_username.value
  db_password = data.aws_ssm_parameter.db_password.value
  db_sg_id    = data.aws_ssm_parameter.db_security_group_id.value
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

locals {
  argocd_bootstrap_files = [
    "${path.module}/../../../kubernetes/argocd/projects/service-track.appproject.yaml",
    "${path.module}/../../../kubernetes/argocd/applications/service-track-${var.environment}.application.yaml",
  ]
}

module "app_secrets" {
  source = "../app-secrets"

  name_prefix = "/${var.project}/${var.environment}"
  tags        = local.tags

  params = merge(
    {
      "jwt-private"         = local.jwt_private_key_pem
      "jwt-public"          = local.jwt_public_key_pem
      "unsplash-access-key" = var.unsplash_access_key
      "resend-api-key"      = var.resend_api_key
    },
    var.app_secret_params,
  )
}

module "datadog_agent" {
  count  = var.observabilidade.habilitada ? 1 : 0
  source = "../datadog-agent"

  name        = local.name
  environment = var.environment

  api_key = var.observabilidade.api_key
  app_key = var.observabilidade.app_key
  site    = var.observabilidade.site

  cluster_name = module.eks.cluster_name

  cluster_agent_replicas = var.observabilidade.cluster_agent_replicas
  espalhar_por_az        = var.observabilidade.espalhar_por_az
  coletar_logs           = var.observabilidade.coletar_logs
  coletar_traces         = var.observabilidade.coletar_traces

  recursos_node_agent    = var.observabilidade.recursos_node_agent
  recursos_cluster_agent = var.observabilidade.recursos_cluster_agent

  depends_on_node_group = module.eks.node_group
}

module "observability" {
  count  = var.observabilidade.habilitada && var.observabilidade.app_key != "" ? 1 : 0
  source = "../observability"

  environment  = var.environment
  notificacao  = var.observabilidade.notificacao
  tags_monitor = ["env:${var.environment}", "projeto:servicetrack", "gerenciado:terraform"]

  limite_latencia_p95_segundos = var.observabilidade.limite_latencia_p95_segundos
  limite_erros_5xx             = var.observabilidade.limite_erros_5xx
  limite_falhas_os             = var.observabilidade.limite_falhas_os
  limite_falhas_integracao     = var.observabilidade.limite_falhas_integracao
  minimo_de_pods               = var.observabilidade.minimo_de_pods
  limite_saturacao             = var.observabilidade.limite_saturacao
  limite_uso_de_conexoes       = var.observabilidade.limite_uso_de_conexoes

  depends_on = [module.datadog_agent]
}

resource "aws_ssm_parameter" "gateway_shared_secret" {
  name  = "/${var.project}/${var.environment}/gateway/shared-secret"
  type  = "SecureString"
  value = local.gateway_shared_secret
  tags  = local.tags
}

resource "aws_ssm_parameter" "api_base_url" {
  name  = "/${var.project}/${var.environment}/api/base-url"
  type  = "String"
  value = module.api_gateway.api_endpoint
  tags  = local.tags
}

resource "null_resource" "app_secrets_bootstrap" {
  count = var.bootstrap_argocd_apps && length(module.app_secrets.parameter_names) > 0 ? 1 : 0

  triggers = {
    params   = join(",", module.app_secrets.parameter_names)
    cluster  = module.eks.cluster_name
    base_url = aws_ssm_parameter.api_base_url.value
    segredo  = sha256(local.gateway_shared_secret)
  }

  provisioner "local-exec" {
    command = "${path.module}/../../../scripts/app-secrets-bootstrap.sh ${module.eks.cluster_name} ${data.aws_region.current.name} ${module.app_secrets.name_prefix}"
  }

  depends_on = [module.addons, aws_ssm_parameter.api_base_url, aws_ssm_parameter.gateway_shared_secret]
}

resource "null_resource" "argocd_bootstrap" {
  count = var.bootstrap_argocd_apps ? 1 : 0

  triggers = {
    manifests = join(",", [for f in local.argocd_bootstrap_files : filesha1(f)])
    cluster   = module.eks.cluster_name
  }

  provisioner "local-exec" {
    command = "${path.module}/../../../scripts/argocd-bootstrap-apply.sh ${module.eks.cluster_name} ${data.aws_region.current.name} ${var.environment}"
  }

  depends_on = [module.addons, null_resource.app_secrets_bootstrap]
}

module "ecr_app" {
  source = "../ecr"

  repository_name      = "${local.name}-app"
  image_tag_mutability = "IMMUTABLE"
  max_image_count      = var.ecr_max_image_count
  tags                 = local.tags
}

module "ecr_lambda" {
  source = "../ecr"

  repository_name      = "${local.name}-auth-lambda"
  image_tag_mutability = "MUTABLE"
  max_image_count      = var.ecr_max_image_count
  tags                 = local.tags
}

module "lambda_auth" {
  source = "../lambda"

  name               = "${local.name}-auth"
  tags               = local.tags
  image_uri          = "${module.ecr_lambda.repository_url}:${var.lambda_image_tag}"
  lab_role_arn       = data.aws_iam_role.lab.arn
  vpc_id             = local.vpc_id
  private_subnet_ids = local.private_subnet_ids
  memory_size        = var.lambda_memory_size
  timeout            = var.lambda_timeout

  db_host     = local.db_endpoint
  db_port     = local.db_port
  db_name     = local.db_name
  db_user     = local.db_username
  db_password = local.db_password

  db_pool_max_size = tonumber(data.aws_ssm_parameter.pool_lambda_max_size.value)

  jwt_issuer             = var.jwt_issuer
  jwt_expiration_seconds = var.jwt_expiration_seconds
  extra_env              = local.lambda_env
}

resource "aws_security_group_rule" "rds_from_eks" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  description              = "PostgreSQL a partir dos nodes do EKS"
  security_group_id        = local.db_sg_id
  source_security_group_id = module.eks.cluster_security_group_id
}

resource "aws_security_group_rule" "rds_from_lambda" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  description              = "PostgreSQL a partir da Lambda de autenticacao"
  security_group_id        = local.db_sg_id
  source_security_group_id = module.lambda_auth.security_group_id
}

module "vpc_link" {
  source = "../vpc-link"

  name                   = local.name
  tags                   = local.tags
  vpc_id                 = local.vpc_id
  vpc_cidr               = local.vpc_cidr
  private_subnet_ids     = local.private_subnet_ids
  node_asg_names         = module.eks.node_group_asg_names
  node_security_group_id = module.eks.cluster_security_group_id
  node_port              = var.app_node_port
  health_check_protocol  = var.app_health_check_protocol
  health_check_path      = var.app_health_check_path
}

module "jwt_authorizer" {
  source = "../lambda-authorizer"
  count  = var.enable_jwt_authorizer ? 1 : 0

  name               = "${local.name}-jwt-authorizer"
  tags               = local.tags
  lab_role_arn       = data.aws_iam_role.lab.arn
  jwt_public_key     = local.jwt_public_key
  jwt_issuer         = var.jwt_issuer
  jwt_leeway_seconds = var.jwt_leeway_seconds
}

module "api_gateway" {
  source = "../api-gateway"

  name        = local.name
  environment = var.environment
  tags        = local.tags

  openapi_path           = "${local.api_ext_dir}/openApi.yaml"
  cors_config_path       = "${local.api_ext_dir}/api-configuration/cors/config-${local.env_suffix}.yaml"
  usage_plan_config_path = "${local.api_ext_dir}/api-configuration/usage-plan/config-${local.env_suffix}.yaml"

  auth_lambda_function_name = module.lambda_auth.function_name
  auth_lambda_invoke_arn    = module.lambda_auth.invoke_arn

  app_backend_host = module.vpc_link.nlb_dns_name
  vpc_link_id      = module.vpc_link.vpc_link_id

  gateway_shared_secret = local.gateway_shared_secret

  authorizer_invoke_arn         = var.enable_jwt_authorizer ? module.jwt_authorizer[0].invoke_arn : null
  authorizer_function_name      = var.enable_jwt_authorizer ? module.jwt_authorizer[0].function_name : null
  authorizer_result_ttl_seconds = var.authorizer_result_ttl_seconds


  enable_access_logs  = var.enable_api_access_logs
  cloudwatch_role_arn = data.aws_iam_role.lab.arn
}
