# ADR-004 — Fronteira entre o EXT e o Terraform

- **Status:** aceito
- **Data:** 2026-07-23

## Contexto

O diretório `apis/service-track-api-ext/` e o diretório `iac/` podem facilmente
descrever a mesma coisa duas vezes: CORS declarado no OpenAPI e de novo em HCL,
throttling no contrato e de novo no usage plan, e assim por diante.

O estado anterior já mostrava o sintoma: `api-configuration/config-PRD.yaml`
estava no formato do **Axway API Manager** (`backendBasePath`, `inboundProfiles`,
`corsConfigFile`) e apontava para `./cors/cors-profile-prd.json` e
`./usage-plan/usage-plan-profile-prd.json` — **arquivos que não existiam**.
`config-HML.yaml` estava vazio. Nada disso era lido por nada.

## Decisão

A fronteira é:

> **EXT responde "como a API é exposta". Terraform responde "quais recursos AWS
> precisam existir".**

Quando uma configuração pode ser expressa no OpenAPI, ela fica no OpenAPI.

### O que pertence ao EXT (`apis/service-track-api-ext/`)

| Arquivo | Conteúdo |
|---|---|
| `openApi.yaml` | rotas, métodos, parâmetros, headers, request/response, schemas, validação, `security` por operação, integrações |
| `api-configuration/cors/config-<ENV>.yaml` | origem, métodos, headers, `maxAge`, credenciais |
| `api-configuration/usage-plan/config-<ENV>.yaml` | rate/burst e quota por API key; rate/burst do stage; nível de log; retenção |

### O que pertence ao Terraform (`iac/`)

Provisionar: REST API, stage, deployment, usage plan, API key, VPC Link, NLB,
target group, log groups, gateway responses, permissão da Lambda. E **ler** os
arquivos acima para preencher esses recursos.

### O que deliberadamente NÃO se repete

| Configuração | Onde vive | Como chega ao outro lado |
|---|---|---|
| Exigência de API key por rota | `security:` no OpenAPI | importação vira `apiKeyRequired` no método |
| Valores de CORS | `cors/config-<ENV>.yaml` | `yamldecode` no Terraform monta o OPTIONS e injeta no OpenAPI |
| Limites de throttling | `usage-plan/config-<ENV>.yaml` | `yamldecode` preenche `aws_api_gateway_usage_plan` |
| Rotas e schemas | `openApi.yaml` | `aws_api_gateway_rest_api.body` |
| Endereço dos backends | Terraform (outputs) | injetado como placeholder no OpenAPI |

Nenhum desses itens está escrito em dois lugares.

## O caso do CORS

CORS é o único ponto onde a separação exigiu uma decisão não óbvia. O bloco
`options:` de preflight tem ~25 linhas e precisaria aparecer em cada um dos 36
paths — 900 linhas de boilerplate idêntico dentro do contrato.

Solução: o método OPTIONS é montado **uma vez** no Terraform a partir do YAML de
CORS e injetado no contrato como `options: ${cors_options}` — uma linha por path.
Os valores continuam versionados no EXT; só a repetição foi eliminada.

## Reorganização de `api-configuration/`

Antes (não funcional):

```
api-configuration/
├── config-HML.yaml   (vazio)
└── config-PRD.yaml   (formato Axway, apontando para arquivos inexistentes)
```

Depois:

```
api-configuration/
├── cors/
│   ├── config-HML.yaml
│   └── config-PRD.yaml
└── usage-plan/
    ├── config-HML.yaml
    └── config-PRD.yaml
```

Só dois agrupamentos, porque só existem dois eixos de configuração por ambiente.
**Não** foi criado `authorizers/`: não há authorizer no gateway
(ver [ADR-005](ADR-005-autorizacao-jwt-no-backend.md)), e criar o diretório vazio
seria estrutura sem conteúdo.

A intenção do `path: /service-track/v1` do arquivo Axway foi preservada
conceitualmente: hoje o base path é `/{stage}`, e um domínio customizado poderia
mapear `/service-track/v1` para o stage sem alterar o contrato.

## Consequências

- Os dois arquivos antigos foram **removidos**. Estavam quebrados, vazios ou
  descreviam um produto (Axway) que não é usado nesta infraestrutura.
- Alterar limite de throttling ou origem de CORS é editar YAML no EXT e rodar
  `terraform apply`. Não se toca em HCL.
- O Terraform passou a depender de arquivos fora de `iac/`. O caminho é resolvido
  por `path.module` em `modules/stack`, então funciona a partir de qualquer
  ambiente.
