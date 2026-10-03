module "stack" {
  source = "../../modules/stack"

  project     = "servicetrack"
  environment = "hml"

  cluster_version     = ""
  node_instance_types = ["t3.medium"]
  node_desired_size   = 1
  node_min_size       = 1
  node_max_size       = 1

  argocd_expose_lb      = var.argocd_expose_lb
  bootstrap_argocd_apps = var.bootstrap_argocd_apps

  habilitar_autenticacao = var.habilitar_autenticacao
  habilitar_borda        = var.habilitar_borda
  habilitar_api_interna  = var.habilitar_api_interna

  lambda_memory_size = 512
  lambda_timeout     = 30
  lambda_extra_env   = var.lambda_extra_env

  enable_jwt_authorizer = var.enable_jwt_authorizer
  jwt_public_key        = var.jwt_public_key
}
