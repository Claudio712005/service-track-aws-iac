module "stack" {
  source = "../../modules/stack"

  project     = "servicetrack"
  environment = "hml"

  vpc_cidr             = "10.10.0.0/16"
  azs                  = ["us-east-1a", "us-east-1b"]
  public_subnet_cidrs  = ["10.10.0.0/20", "10.10.16.0/20"]
  private_subnet_cidrs = ["10.10.48.0/20", "10.10.64.0/20"]

  cluster_version     = "1.30"
  node_instance_types = ["t3.small"]
  node_desired_size   = 1
  node_min_size       = 1
  node_max_size       = 2

  db_instance_class    = "db.t3.micro"
  db_allocated_storage = 20

  lambda_image_tag   = var.lambda_image_tag
  lambda_memory_size = 512
  lambda_timeout     = 30
  lambda_extra_env   = var.lambda_extra_env

  # Sem LoadBalancer para o ArgoCD em HML: economiza ~US$ 16/mes.
  # Acesso por: kubectl -n argocd port-forward svc/argocd-server 8080:80
  argocd_expose_lb = false

  enable_jwt_authorizer = var.enable_jwt_authorizer
  jwt_public_key        = var.jwt_public_key
}
