output "dashboard_url" {
  value = datadog_dashboard.servicetrack.url
}

output "monitores" {
  value = {
    latencia    = datadog_monitor.latencia_da_api.id
    erros_5xx   = datadog_monitor.erros_5xx.id
    falhas_os   = datadog_monitor.falha_no_processamento_de_os.id
    pods        = datadog_monitor.saude_dos_pods.id
    saturacao   = datadog_monitor.recursos_do_cluster.id
    integracoes = datadog_monitor.erros_de_integracao.id
  }
}
