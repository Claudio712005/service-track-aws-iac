resource "kubernetes_namespace" "datadog" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_secret" "datadog_keys" {
  metadata {
    name      = "datadog-keys"
    namespace = kubernetes_namespace.datadog.metadata[0].name
  }

  data = {
    "api-key" = var.api_key
    "app-key" = var.app_key
  }

  type = "Opaque"
}

locals {
  valores = {
    datadog = {
      clusterName = var.cluster_name
      site        = var.site

      apiKeyExistingSecret = kubernetes_secret.datadog_keys.metadata[0].name
      appKeyExistingSecret = var.app_key != "" ? kubernetes_secret.datadog_keys.metadata[0].name : null

      tags = [
        "env:${var.environment}",
        "projeto:servicetrack",
      ]

      env = [
        {
          name  = "DD_ENV"
          value = var.environment
        },
      ]

      kubelet = {
        tlsVerify = false
      }

      logs = {
        enabled             = var.coletar_logs
        containerCollectAll = var.coletar_logs
      }

      apm = {
        portEnabled = var.coletar_traces
        instrumentation = {
          enabled = false
        }
      }

      otlp = {
        receiver = {
          protocols = {
            grpc = {
              enabled     = true
              endpoint    = "0.0.0.0:4317"
              useHostPort = true
            }
            http = {
              enabled     = true
              endpoint    = "0.0.0.0:4318"
              useHostPort = true
            }
          }
        }
      }

      processAgent = {
        enabled           = true
        processCollection = false
      }

      dogstatsd = {
        useHostPort = true
      }
    }

    agents = {
      resources = {
        requests = {
          cpu    = var.recursos_node_agent.requests_cpu
          memory = var.recursos_node_agent.requests_memory
        }
        limits = {
          cpu    = var.recursos_node_agent.limits_cpu
          memory = var.recursos_node_agent.limits_memory
        }
      }
      tolerations = [
        {
          operator = "Exists"
        },
      ]
    }

    clusterAgent = {
      enabled  = true
      replicas = var.cluster_agent_replicas

      resources = {
        requests = {
          cpu    = var.recursos_cluster_agent.requests_cpu
          memory = var.recursos_cluster_agent.requests_memory
        }
        limits = {
          cpu    = var.recursos_cluster_agent.limits_cpu
          memory = var.recursos_cluster_agent.limits_memory
        }
      }

      createPodDisruptionBudget = var.cluster_agent_replicas > 1

      podAnnotations = {
        "ambiente" = var.environment
      }

      affinity = var.espalhar_por_az ? {
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [
            {
              labelSelector = {
                matchLabels = {
                  app = "${var.name}-datadog-cluster-agent"
                }
              }
              topologyKey = "topology.kubernetes.io/zone"
            },
          ]
        }
      } : {}
    }

    clusterChecksRunner = {
      enabled = false
    }
  }
}

resource "helm_release" "datadog" {
  name       = "${var.name}-datadog"
  namespace  = kubernetes_namespace.datadog.metadata[0].name
  repository = "https://helm.datadoghq.com"
  chart      = "datadog"
  version    = var.chart_version

  timeout = 900
  atomic  = true

  values = [yamlencode(local.valores)]

  set {
    name  = "datadog.apm.errorTrackingStandalone.enabled"
    value = "false"
  }

  depends_on = [var.depends_on_node_group]
}
