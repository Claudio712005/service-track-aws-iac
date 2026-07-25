module "stack" {
  source = "../../modules/stack"

  project     = "servicetrack"
  environment = "prd"

  vpc_cidr             = "10.20.0.0/16"
  azs                  = ["us-east-1a", "us-east-1b"]
  public_subnet_cidrs  = ["10.20.0.0/20", "10.20.16.0/20"]
  private_subnet_cidrs = ["10.20.48.0/20", "10.20.64.0/20"]

  cluster_version     = "1.30"
  node_instance_types = ["t3.large"]
  node_desired_size   = 2
  node_min_size       = 2
  node_max_size       = 4

  db_instance_class    = "db.t3.medium"
  db_allocated_storage = 50

  lambda_image_tag   = var.lambda_image_tag
  lambda_memory_size = 1024
  lambda_timeout     = 30
  lambda_extra_env   = var.lambda_extra_env

  argocd_expose_lb = true

  enable_jwt_authorizer = var.enable_jwt_authorizer
  jwt_public_key        = var.jwt_public_key
  # Ligado so depois que a delegacao NS existe no Registro.br. A esteira
  # dns-publish.yml verifica a delegacao e reaplica com true. Ver ADR-008.
  custom_domain = var.enable_custom_domain ? {
    domain_name      = var.api_domain_name
    hosted_zone_name = var.api_hosted_zone_name
    base_path        = var.api_base_path
  } : null
  bootstrap_argocd_apps = var.bootstrap_argocd_apps
  app_secret_params     = var.app_secret_params
}
