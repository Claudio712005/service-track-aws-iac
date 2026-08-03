module "stack" {
  source = "../../modules/stack"

  project     = "servicetrack"
  environment = "prd"

  cluster_version     = "1.30"
  node_instance_types = ["t3.large"]
  node_desired_size   = 2
  node_min_size       = 2
  node_max_size       = 4

  lambda_image_tag   = var.lambda_image_tag
  lambda_memory_size = 1024
  lambda_timeout     = 30
  lambda_extra_env   = var.lambda_extra_env

  argocd_expose_lb = true

  enable_jwt_authorizer = var.enable_jwt_authorizer
  jwt_public_key        = var.jwt_public_key
  custom_domain = var.enable_custom_domain ? {
    domain_name      = var.api_domain_name
    hosted_zone_name = var.api_hosted_zone_name
    base_path        = var.api_base_path
  } : null
  bootstrap_argocd_apps = var.bootstrap_argocd_apps
  app_secret_params     = var.app_secret_params

  observabilidade = {
    habilitada  = var.datadog_api_key != ""
    api_key     = var.datadog_api_key
    app_key     = var.datadog_app_key
    site        = var.datadog_site
    notificacao = var.datadog_notificacao

    cluster_agent_replicas = 2
    espalhar_por_az        = true
    coletar_logs           = true
    coletar_traces         = true

    recursos_node_agent = {
      requests_cpu    = "200m"
      requests_memory = "512Mi"
      limits_cpu      = "700m"
      limits_memory   = "1Gi"
    }

    recursos_cluster_agent = {
      requests_cpu    = "200m"
      requests_memory = "256Mi"
      limits_cpu      = "500m"
      limits_memory   = "512Mi"
    }

    limite_latencia_p95_segundos = 1.5
    limite_erros_5xx             = 10
    limite_falhas_os             = 5
    limite_falhas_integracao     = 10
    minimo_de_pods               = 2
    limite_saturacao             = 0.8
    limite_uso_de_conexoes       = 0.75
  }
}
