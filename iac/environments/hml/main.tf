module "stack" {
  source = "../../modules/stack"

  project     = "servicetrack"
  environment = "hml"


  cluster_version     = "1.30"
  node_instance_types = ["t3.small"]
  node_desired_size   = 1
  node_min_size       = 1
  node_max_size       = 2


  lambda_image_tag   = var.lambda_image_tag
  lambda_memory_size = 512
  lambda_timeout     = 30
  lambda_extra_env   = var.lambda_extra_env

  # Sem LoadBalancer para o ArgoCD em HML: economiza ~US$ 16/mes.
  # Acesso por: kubectl -n argocd port-forward svc/argocd-server 8080:80
  argocd_expose_lb = false

  enable_jwt_authorizer = var.enable_jwt_authorizer
  jwt_public_key        = var.jwt_public_key
  bootstrap_argocd_apps = var.bootstrap_argocd_apps
  app_secret_params     = var.app_secret_params
}
