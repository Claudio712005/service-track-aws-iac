# ADR-002 — O OpenAPI é a definição do gateway, não documentação paralela

- **Status:** aceito
- **Data:** 2026-07-23

## Contexto

`apis/service-track-api-ext/openApi.yaml` existia como documentação exportada da
aplicação. Tinha 3.643 linhas, `servers: http://localhost:8080` e — problema
imediato — a primeira linha era `penapi: 3.0.3` em vez de `openapi: 3.0.3`, o que
tornava o arquivo **inválido**. Nada consumia esse arquivo, então o erro nunca
apareceu.

Havia duas formas de provisionar as rotas no API Gateway:

1. Declarar cada `aws_api_gateway_resource` / `_method` / `_integration` em HCL.
2. Importar o documento OpenAPI via `aws_api_gateway_rest_api.body`.

## Decisão

O `openApi.yaml` **é** a definição do gateway. O Terraform o importa em
`aws_api_gateway_rest_api.body` via `templatefile()`, injetando os valores que só
existem em tempo de apply.

## Justificativa

- 36 paths e 49 operações em HCL seriam ~150 recursos Terraform escritos à mão.
  Em OpenAPI é um documento só, e é o formato que a AWS aceita nativamente.
- Elimina a classe de bug "contrato e gateway divergiram": só existe uma fonte.
- Request validation depende de os schemas estarem no gateway. Importando o
  OpenAPI, os `components.schemas` viram Models automaticamente. Em HCL seria
  preciso duplicar cada schema em `aws_api_gateway_model`.
- O arquivo continua legível como contrato para quem consome a API.

## Como os valores dinâmicos entram

O arquivo é um template. Quatro placeholders são resolvidos no apply:

| Placeholder | Origem |
|---|---|
| `${auth_lambda_uri}` | `module.lambda_auth.invoke_arn` |
| `${app_backend_host}` | DNS do NLB interno (`module.vpc_link.nlb_dns_name`) |
| `${vpc_link_id}` | `module.vpc_link.vpc_link_id` |
| `${cors_options}` | método OPTIONS montado a partir de `api-configuration/cors/config-<ENV>.yaml` |

Nenhum ID de conta, ARN ou hostname fica versionado.

## O que foi removido do contrato e por quê

O arquivo passou de **3.643 para 2.487 linhas** (−32%) mesmo tendo **ganhado** as
49 integrações e os 36 blocos de preflight. O conteúdo puramente documental saiu:

| Removido | Motivo |
|---|---|
| `tags` e o bloco `tags:` de topo | O API Gateway ignora. Servia só para agrupar no Swagger UI. |
| `summary` e `description` de operações | Ignorados na importação. Eram prosa longa em português. |
| `example` / `examples` em schemas e respostas | Ignorados. Respondiam por boa parte das linhas (o bloco do dashboard sozinho tinha ~180 linhas de exemplo). |
| `info.description`, `info.contact`, `info.license` | Documentação institucional, sem efeito no gateway. |
| `description` de cada propriedade de schema | Não afeta validação. `type`, `format`, `required`, `enum`, `minLength`, `minimum` foram **mantidos**. |
| `x-column` / `x-icon` (dashboard) | Extensões de UI, sem relação com a API. |
| `securitySchemes.SecurityScheme` | Duplicata literal de `bearerAuth`, sem uso. |

O que foi **mantido** por ser tecnicamente necessário: paths, métodos,
parâmetros (com `required` e schema), request bodies, status codes, schemas
completos, `security` e as integrações.

## O que foi acrescentado

- Schemas nomeados no lugar de schemas inline: `GerarOrcamentoRequest`,
  `TempoMedioConclusaoResponse`, `DashboardClienteResponse`,
  `ItemServicoDiagnosticado`, `ItemInsumoDiagnosticado`, `StatusOrdemServico`,
  `NivelMecanico`. O API Gateway cria um Model por schema; nomear evita models
  anônimos e remove a duplicação do enum de status, que aparecia 5 vezes.
- `components/parameters` e `components/responses` reutilizáveis.
- `servers` parametrizado (ver abaixo).

## `servers`

O valor antigo (`http://localhost:8080`) descrevia o ambiente de desenvolvimento
da aplicação, não a exposição pela AWS. Foi substituído por uma URL com variáveis
de servidor:

```yaml
servers:
- url: https://{apiId}.execute-api.{region}.amazonaws.com/{stage}
  variables:
    apiId:  { default: apiid }
    region: { default: us-east-1 }
    stage:  { default: hml, enum: [hml, prd] }
```

Não há URL de HML nem de PRD escrita no arquivo. O `apiId` real sai do output
`api_gateway_id` e muda a cada recriação do ambiente — hardcodar seria garantir
divergência. O `servers` é ignorado na importação; ele existe para o consumidor
do contrato.

## Consequências

- Editar rotas exige rodar `scripts/validate-openapi.sh` antes do apply. O script
  resolve os placeholders com valores fake e valida o documento final.
- Como o arquivo tem placeholders, ele não é um OpenAPI válido "cru". Essa é a
  troca aceita: um arquivo válido cru exigiria hardcodar ARNs.
- Qualquer mudança no body dispara novo `aws_api_gateway_deployment`
  (trigger `sha1(local.body)`), então a mudança sempre chega ao stage.
