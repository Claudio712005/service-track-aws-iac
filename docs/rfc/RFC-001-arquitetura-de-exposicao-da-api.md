# RFC-001 — Arquitetura de exposição da Service Track API

- **Status:** implementado
- **Data:** 2026-07-23
- **ADRs relacionados:** [001](../adr/ADR-001-api-gateway-rest-vs-http.md),
  [002](../adr/ADR-002-openapi-como-definicao-do-gateway.md),
  [003](../adr/ADR-003-integracao-backend-eks-vpc-link.md),
  [004](../adr/ADR-004-fronteira-ext-terraform.md),
  [005](../adr/ADR-005-autorizacao-jwt-no-backend.md),
  [006](../adr/ADR-006-ambientes-efemeros-e-conta-educacional.md),
  [007](../adr/ADR-007-lambda-authorizer-opcional.md),
  [008](../adr/ADR-008-dominio-customizado-opcional.md),
  [009](../adr/ADR-009-multiplas-api-keys-por-consumidor.md),
  [010](../adr/ADR-010-contract-testing-na-pipeline.md)

## 1. Problema

A Service Track API estava provisionada, mas não **exposta**. O estado inicial:

- Um HTTP API v2 com `ANY /{proxy+}` apontando para a Lambda de autenticação.
  Só o login era alcançável de fora.
- A aplicação no EKS não tinha nenhuma porta de entrada. O único LoadBalancer da
  conta era o do ArgoCD.
- `openApi.yaml` inválido (primeira linha `penapi:` em vez de `openapi:`), com
  `servers: http://localhost:8080`, não consumido por nada.
- `api-configuration/config-HML.yaml` vazio e `config-PRD.yaml` no formato do
  Axway API Manager, referenciando arquivos inexistentes.
- Sem API Key, sem throttling, sem quota, sem CORS, sem validação de request.

Objetivo: expor a API inteira por serviços AWS, com toda a configuração
reproduzível por IaC, em dois ambientes efêmeros.

## 2. Arquitetura resultante

```
                        Internet
                            │
                            ▼
        ┌───────────────────────────────────────────┐
        │   API Gateway REST API (regional)         │
        │   stage: hml | prd                        │
        │                                           │
        │   definido por openApi.yaml               │
        │   ├── API Key (x-api-key) + Usage Plan    │
        │   ├── throttling e quota                  │
        │   ├── request validation (JSON Schema)    │
        │   └── CORS (preflight + respostas de erro)│
        └───────────┬───────────────────┬───────────┘
                    │                   │
   /autenticacao*   │                   │  demais 47 operações
      (aws_proxy)   │                   │  (http_proxy + VPC_LINK)
                    ▼                   ▼
        ┌────────────────────┐    ┌──────────────┐
        │ Lambda auth        │    │  VPC Link    │
        │ (imagem Quarkus)   │    └──────┬───────┘
        │ subnets privadas   │           ▼
        └─────────┬──────────┘    ┌──────────────┐
                  │               │ NLB interno  │
                  │               │ subnets priv.│
                  │               └──────┬───────┘
                  │                      │ TCP :30080 (NodePort)
                  │                      ▼
                  │               ┌──────────────┐
                  │               │ EKS nodes    │
                  │               │ (ASG do node │
                  │               │  group)      │
                  │               └──────┬───────┘
                  │                      │
                  └──────────┬───────────┘
                             ▼
                    ┌─────────────────┐
                    │  RDS PostgreSQL │
                    │  subnets priv.  │
                    └─────────────────┘
```

Todo o tráfego externo entra por um único ponto. O NLB é **interno**: não existe
caminho que contorne o gateway e, com isso, o API Key e o throttling.

## 3. Divisão de responsabilidade

| Pergunta | Responde | Arquivos |
|---|---|---|
| *Como a API é exposta?* | **EXT** | `apis/service-track-api-ext/` |
| *Quais recursos AWS precisam existir?* | **Terraform** | `iac/` |

Detalhado em [ADR-004](../adr/ADR-004-fronteira-ext-terraform.md). O ponto
central: nenhuma configuração aparece nos dois lados. O Terraform **lê** os
arquivos do EXT (`yamldecode`, `templatefile`) e os traduz em recursos AWS.

## 4. Fluxo de uma requisição

`GET /clientes/{id}` em HML:

1. Cliente chama `https://{apiId}.execute-api.us-east-1.amazonaws.com/hml/clientes/abc`
   com `x-api-key` e `Authorization: Bearer <jwt>`.
2. Gateway verifica a API Key contra o Usage Plan. Sem chave → 403 (com headers
   CORS, via `gateway_response`).
3. Gateway aplica throttling: do stage (50 req/s em hml) e do usage plan
   (20 req/s por chave). Estouro → 429.
4. Request validator confere path params e, em rotas com body, o JSON Schema.
   Inválido → 400 sem chegar ao backend.
5. Integração `http_proxy` mapeia `method.request.path.id` para
   `integration.request.path.id` e chama
   `http://<nlb-dns>/clientes/{id}` pelo VPC Link.
6. NLB entrega no NodePort 30080 de um node saudável.
7. A aplicação valida o JWT (MicroProfile JWT) e aplica a autorização de domínio
   (CLIENTE só vê os próprios dados).
8. Resposta volta pelo mesmo caminho.

Para `POST /autenticacao` os passos 5–7 são substituídos por invocação direta da
Lambda (`aws_proxy`), que emite o JWT.

## 5. Ambientes

| | HML | PRD |
|---|---|---|
| State S3 | `servicetrack/hml` | `servicetrack/prd` |
| VPC | `10.10.0.0/16` | `10.20.0.0/16` |
| Stage | `hml` | `prd` |
| Throttle por chave | 20 req/s, burst 40 | 100 req/s, burst 200 |
| Quota | 10.000/dia | 200.000/mês |
| Throttle do stage | 50 / 100 | 200 / 400 |
| Métricas por método | ligadas | desligadas (custo) |
| Log level | `INFO` | `ERROR` |
| Retenção de log | 7 dias | 14 dias |
| CORS `maxAge` | 300s | 3600s |

Os dois ambientes usam o **mesmo** `openApi.yaml`. Só divergem nos arquivos de
`api-configuration/` e no sizing já existente em `environments/<env>/main.tf`.

## 6. Reprodutibilidade

`terraform destroy` → `terraform apply` reconstrói: REST API, todas as 36 rotas,
os 49 métodos, os 36 preflights, models de validação, stage, deployment, usage
plan, API key, VPC Link, NLB, target group, gateway responses e permissão da
Lambda.

Nada é importado à mão. Nada é clicado no console.

Muda a cada recriação (por design, não por limitação):

- o **ID da API**, logo a URL — output `api_gateway_url`;
- o **valor das API keys** — output `api_key_values`, um por consumidor
  ([ADR-006](../adr/ADR-006-ambientes-efemeros-e-conta-educacional.md), seção 3).
  Com domínio customizado ([ADR-008](../adr/ADR-008-dominio-customizado-opcional.md))
  a URL deixa de mudar;
- o **DNS do NLB** — resolvido automaticamente, pois é injetado no contrato no
  momento do apply.

## 7. Riscos conhecidos

| Risco | Impacto | Mitigação |
|---|---|---|
| `LabRole` não assumível por `apigateway.amazonaws.com` | apply falha em `aws_api_gateway_account` | `-var="enable_api_access_logs=false"` |
| Service do EKS não é NodePort 30080 | target group unhealthy, gateway responde 503 | `var.app_node_port` parametrizado; infra sobe normalmente |
| Divisão auth Lambda × EKS inferida, não confirmada | rota de cadastro no backend errado | trocar o bloco de integração no `openApi.yaml`, sem mexer em Terraform |
| Permissões da `LabRole` para NLB / VPC Link | apply falha | verificar na primeira execução em HML |
| Validação de request rejeitar payload legítimo | 400 indevido | schemas derivados do contrato original; testar em HML antes de PRD |

## 8. Evolução possível

### Implementado depois da versão inicial

| Item | Estado | ADR |
|---|---|---|
| Domínio customizado com base path `/service-track/v1` | opcional, default desligado | [008](../adr/ADR-008-dominio-customizado-opcional.md) |
| Múltiplas API keys, uma por consumidor | ativo | [009](../adr/ADR-009-multiplas-api-keys-por-consumidor.md) |
| Lambda authorizer de JWT na borda | opcional, default desligado | [007](../adr/ADR-007-lambda-authorizer-opcional.md) |
| Contract testing na pipeline | ativo (estático em push, dinâmico pós-apply) | [010](../adr/ADR-010-contract-testing-na-pipeline.md) |

### Ainda em aberto

- **Contract testing provider × consumer de verdade**: comparar o `openApi.yaml`
  com o contrato gerado pela aplicação no EKS. Depende de a aplicação publicar seu
  OpenAPI num local estável — hoje ele vive em outro repositório.
- **Fechar o endpoint `execute-api`** quando o domínio customizado estiver ativo,
  via resource policy, para ter um único ponto de entrada.
- **WAF** se a API passar a receber tráfego real não confiável.
- **Chave estável entre recriações** (Secrets Manager) se algum consumidor não
  puder reconfigurar a API key a cada ambiente novo.
