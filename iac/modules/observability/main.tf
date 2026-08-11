locals {
  escopo = "env:${var.environment},projeto:servicetrack"
  sufixo = upper(var.environment)
}

resource "datadog_monitor" "latencia_da_api" {
  name = "[${local.sufixo}] Latencia alta na API"
  type = "query alert"

  message = <<-EOT
    A latencia p95 da API passou do limite por mais de 10 minutos.

    Onde olhar: saturacao do HPA, consultas lentas no banco (pg_stat_statements)
    e latencia das integracoes externas.

    ${var.notificacao}
  EOT

  query = "avg(last_10m):p95:trace.http.server.request{${local.escopo}} > ${var.limite_latencia_p95_segundos}"

  monitor_thresholds {
    critical = var.limite_latencia_p95_segundos
    warning  = var.limite_latencia_p95_segundos * 0.7
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = var.tags_monitor
}

resource "datadog_monitor" "erros_5xx" {
  name = "[${local.sufixo}] Taxa de erro 5xx na API"
  type = "query alert"

  message = <<-EOT
    A API esta respondendo 5xx acima do limite aceito.

    ${var.notificacao}
  EOT

  query = "sum(last_5m):sum:trace.http.server.request.errors{${local.escopo}}.as_count() > ${var.limite_erros_5xx}"

  monitor_thresholds {
    critical = var.limite_erros_5xx
    warning  = max(floor(var.limite_erros_5xx / 2), 1)
  }

  notify_no_data    = false
  renotify_interval = 30
  tags              = var.tags_monitor
}

resource "datadog_monitor" "falha_no_processamento_de_os" {
  name = "[${local.sufixo}] Falha no processamento de ordens de servico"
  type = "query alert"

  message = <<-EOT
    Erros no processamento de ordens de servico nos ultimos 15 minutos.

    A metrica vem do interceptor de casos de uso. Para achar a causa, filtre os
    logs por erro_codigo comecando em OS_ e siga o traceId da linha.

    ${var.notificacao}
  EOT

  query = "sum(last_15m):sum:servicetrack.usecase.execucoes{entidade:ordem_servico,resultado:erro,${local.escopo}}.as_count() > ${var.limite_falhas_os}"

  monitor_thresholds {
    critical = var.limite_falhas_os
    warning  = max(floor(var.limite_falhas_os / 2), 1)
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = var.tags_monitor
}

resource "datadog_monitor" "saude_dos_pods" {
  name = "[${local.sufixo}] Pods da aplicacao indisponiveis"
  type = "query alert"

  message = <<-EOT
    O numero de replicas prontas caiu abaixo do minimo.

    Causas frequentes depois de recriar o ambiente: ImagePullBackOff porque o
    ECR voltou vazio, readiness falhando por dependencia do banco, ou secrets
    ausentes porque o bootstrap nao rodou.

    ${var.notificacao}
  EOT

  query = "avg(last_5m):avg:kubernetes_state.deployment.replicas_ready{kube_deployment:service-track-app,${local.escopo}} < ${var.minimo_de_pods}"

  monitor_thresholds {
    critical = var.minimo_de_pods
  }

  notify_no_data    = true
  no_data_timeframe = 20
  renotify_interval = 30
  tags              = var.tags_monitor
}

resource "datadog_monitor" "recursos_do_cluster" {
  name = "[${local.sufixo}] Saturacao de CPU nos nodes"
  type = "query alert"

  message = <<-EOT
    Os nodes estao saturados de CPU. O HPA pode nao conseguir escalar por falta
    de capacidade no node group.

    ${var.notificacao}
  EOT

  query = "avg(last_10m):avg:kubernetes.cpu.usage.total{${local.escopo}} / avg:kubernetes.cpu.capacity{${local.escopo}} > ${var.limite_saturacao}"

  monitor_thresholds {
    critical = var.limite_saturacao
    warning  = var.limite_saturacao * 0.8
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = var.tags_monitor
}

resource "datadog_monitor" "erros_de_integracao" {
  count = var.habilitar_monitores_de_log ? 1 : 0

  name = "[${local.sufixo}] Falhas nas integracoes externas"
  type = "log alert"

  message = <<-EOT
    As integracoes externas (FIPE, Unsplash, envio de e-mail) estao falhando.

    O circuito de fault tolerance pode ter aberto.

    ${var.notificacao}
  EOT

  query = "logs(\"service:service-track-api env:${var.environment} @erro_tipo:IntegracaoExternaException\").index(\"*\").rollup(\"count\").last(\"15m\") > ${var.limite_falhas_integracao}"

  monitor_thresholds {
    critical = var.limite_falhas_integracao
  }

  notify_no_data    = false
  renotify_interval = 120
  tags              = var.tags_monitor
}

resource "datadog_monitor" "banco_sem_conexoes" {
  name = "[${local.sufixo}] Banco proximo do teto de conexoes"
  type = "query alert"

  message = <<-EOT
    O uso de conexoes do PostgreSQL passou do limite seguro.

    O orcamento de conexoes esta declarado em service-track-db-infra. Se o teto
    do HPA subiu sem rever o orcamento, e aqui que aparece.

    ${var.notificacao}
  EOT

  query = "avg(last_5m):avg:postgresql.connections{${local.escopo}} / avg:postgresql.max_connections{${local.escopo}} > ${var.limite_uso_de_conexoes}"

  monitor_thresholds {
    critical = var.limite_uso_de_conexoes
    warning  = var.limite_uso_de_conexoes * 0.8
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = var.tags_monitor
}

resource "datadog_dashboard" "servicetrack" {
  title       = "ServiceTrack — ${local.sufixo}"
  description = "Volume de ordens de servico, tempo por status, saude da API, recursos do cluster e erros de integracao."
  layout_type = "ordered"

  widget {
    timeseries_definition {
      title = "Volume diario de ordens de servico"

      request {
        q = "sum:servicetrack.usecase.execucoes{use_case:os_criar,resultado:sucesso,${local.escopo}}.as_count()"
      }

      request {
        q = "sum:servicetrack.usecase.execucoes{use_case:os_criar_completa,resultado:sucesso,${local.escopo}}.as_count()"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Tempo medio das transicoes de status da ordem de servico"

      request {
        q = "avg:servicetrack.usecase.duracao{entidade:ordem_servico,resultado:sucesso,${local.escopo}} by {use_case}"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Latencia p95 da API por rota"

      request {
        q = "p95:trace.http.server.request{${local.escopo}} by {resource_name}"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Casos de uso mais lentos"

      request {
        q = "avg:servicetrack.usecase.duracao{resultado:sucesso,${local.escopo}} by {use_case}"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Casos de uso com falha, por entidade"

      request {
        q = "sum:servicetrack.usecase.execucoes{resultado:erro,${local.escopo}} by {entidade}.as_count()"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "CPU e memoria dos pods da aplicacao"

      request {
        q = "avg:kubernetes.cpu.usage.total{kube_deployment:service-track-app,${local.escopo}}"
      }

      request {
        q = "avg:kubernetes.memory.usage{kube_deployment:service-track-app,${local.escopo}}"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Replicas prontas e escala do HPA"

      request {
        q = "avg:kubernetes_state.deployment.replicas_ready{kube_deployment:service-track-app,${local.escopo}}"
      }

      request {
        q = "avg:kubernetes_state.deployment.replicas_desired{kube_deployment:service-track-app,${local.escopo}}"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Conexoes em uso no banco"

      request {
        q = "avg:postgresql.connections{${local.escopo}}"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Uptime dos healthchecks"

      request {
        q = "avg:kubernetes_state.container.ready{kube_deployment:service-track-app,${local.escopo}}"
      }
    }
  }
}
