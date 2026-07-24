locals {
  name         = "${var.project}-${var.environment}"
  cluster_name = "${var.project}-${var.environment}"

  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })

  # Contrato de exposicao externa da API (EXT), versionado fora do iac/.
  # A partir de iac/modules/stack, tres niveis acima e a raiz do repositorio.
  api_ext_dir = "${path.module}/../../../apis/service-track-api-ext"
  env_suffix  = upper(var.environment)

  # A chave publica ja e entregue a Lambda de autenticacao por lambda_extra_env;
  # o authorizer reusa a mesma, sem novo segredo.
  jwt_public_key = coalesce(
    var.jwt_public_key,
    lookup(var.lambda_extra_env, "MP_JWT_VERIFY_PUBLICKEY", ""),
  )
}

data "aws_iam_role" "lab" {
  name = "LabRole"
}

module "network" {
  source = "../network"

  name                 = local.name
  tags                 = local.tags
  cluster_name         = local.cluster_name
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

module "eks" {
  source = "../eks"

  name                = local.name
  tags                = local.tags
  cluster_name        = local.cluster_name
  cluster_version     = var.cluster_version
  public_subnet_ids   = module.network.public_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids
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

# Repositorio ECR da imagem da aplicacao (deploy no EKS).
module "ecr_app" {
  source = "../ecr"

  repository_name = "${var.project}-app"
  tags            = local.tags
}

# Repositorio ECR da imagem da Lambda de autenticacao.
module "ecr_lambda" {
  source = "../ecr"

  repository_name = "${local.name}-auth-lambda"
  tags            = local.tags
}

module "rds" {
  source = "../rds"

  name                       = local.name
  tags                       = local.tags
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  allowed_security_group_ids = [module.eks.cluster_security_group_id]
  db_name                    = var.db_name
  db_username                = var.db_username
  db_instance_class          = var.db_instance_class
  db_allocated_storage       = var.db_allocated_storage
  db_engine_version          = var.db_engine_version
}

module "lambda_auth" {
  source = "../lambda"

  name               = "${local.name}-auth"
  tags               = local.tags
  image_uri          = "${module.ecr_lambda.repository_url}:${var.lambda_image_tag}"
  lab_role_arn       = data.aws_iam_role.lab.arn
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  memory_size        = var.lambda_memory_size
  timeout            = var.lambda_timeout

  db_host     = module.rds.address
  db_port     = module.rds.port
  db_name     = module.rds.db_name
  db_user     = module.rds.username
  db_password = module.rds.password

  jwt_issuer             = var.jwt_issuer
  jwt_expiration_seconds = var.jwt_expiration_seconds
  extra_env              = var.lambda_extra_env
}

resource "aws_security_group_rule" "rds_from_lambda" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = module.rds.security_group_id
  source_security_group_id = module.lambda_auth.security_group_id
}

# Caminho privado do API Gateway ate a aplicacao no EKS.
module "vpc_link" {
  source = "../vpc-link"

  name                   = local.name
  tags                   = local.tags
  vpc_id                 = module.network.vpc_id
  vpc_cidr               = var.vpc_cidr
  private_subnet_ids     = module.network.private_subnet_ids
  node_asg_names         = module.eks.node_group_asg_names
  node_security_group_id = module.eks.cluster_security_group_id
  node_port              = var.app_node_port
  health_check_protocol  = var.app_health_check_protocol
  health_check_path      = var.app_health_check_path
}

# Authorizer de JWT na borda. Opcional: por padrao a validacao fica so no
# backend. Ver ADR-007.
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

# API Gateway REST definido pelo contrato EXT. Roteia /autenticacao* para a
# Lambda e o restante para a aplicacao no EKS via VPC Link.
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

  authorizer_invoke_arn         = var.enable_jwt_authorizer ? module.jwt_authorizer[0].invoke_arn : null
  authorizer_function_name      = var.enable_jwt_authorizer ? module.jwt_authorizer[0].function_name : null
  authorizer_result_ttl_seconds = var.authorizer_result_ttl_seconds

  custom_domain = var.custom_domain

  enable_access_logs  = var.enable_api_access_logs
  cloudwatch_role_arn = data.aws_iam_role.lab.arn
}
