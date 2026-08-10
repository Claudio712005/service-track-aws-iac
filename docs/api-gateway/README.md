# API Gateway — guia técnico e operacional

Documentação de como a Service Track API é exposta, operada e alterada.
Para o *porquê* de cada decisão, ver [`docs/adr/`](../adr/) e
[RFC-001](../rfc/RFC-001-arquitetura-de-exposicao-da-api.md).

## Índice

- [Onde fica cada coisa](#onde-fica-cada-coisa)
- [Como o contrato vira infraestrutura](#como-o-contrato-vira-infraestrutura)
- [Executar HML](#executar-hml)
- [Executar PRD](#executar-prd)
- [Consumir a API](#consumir-a-api)
- [Consumidores e API keys](#consumidores-e-api-keys)
- [Usage Plan e throttling](#usage-plan-e-throttling)
- [CORS](#cors)
- [Autenticação e autorização](#autenticação-e-autorização)
- [Validação de request](#validação-de-request)
- [Integração com os backends](#integração-com-os-backends)
- [Observabilidade](#observabilidade)
- [Contract testing](#contract-testing)
- [Destruir e recriar](#destruir-e-recriar)
- [Alterar a API](#alterar-a-api)
- [Troubleshooting](#troubleshooting)

## Onde fica cada coisa

```
apis/service-track-api-ext/
├── openApi.yaml                        contrato = definição do gateway
└── api-configuration/
    ├── cors/config-{HML,PRD}.yaml      origem, métodos, headers, maxAge
    └── usage-plan/config-{HML,PRD}.yaml throttle, quota, log, retenção

iac/modules/
├── api-gateway/       REST API, stage, deployment, usage plans, API keys, logs,
│                      CORS de erro
├── lambda-authorizer/ authorizer de JWT (Go, provided.al2023) + testes
└── vpc-link/          NLB interno, target group, ASG attachment, VPC Link

scripts/
├── validate-openapi.sh   valida o contrato (roda em push/PR)
└── contract-test.sh      testa a API publicada (roda após o apply)
```

## Como o contrato vira infraestrutura

```
openApi.yaml ──┐
               ├── templatefile() ──> aws_api_gateway_rest_api.body ──> AWS
cors/*.yaml ───┤                                   │
usage-plan/*───┘                                   └─> aws_api_gateway_deployment
                                                        └─> aws_api_gateway_stage
```

O Terraform resolve cinco placeholders no contrato durante o apply:

| Placeholder | Valor |
|---|---|
| `${auth_lambda_uri}` | `invoke_arn` da Lambda de autenticação |
| `${app_backend_host}` | DNS do NLB interno |
| `${vpc_link_id}` | ID do VPC Link |
| `${cors_options}` | método OPTIONS montado a partir do YAML de CORS |
| `${bearer_auth_scheme}` | `http/bearer` (ignorado) ou o authorizer de JWT, conforme `enable_jwt_authorizer` |

O `openApi.yaml` **não é** um documento válido "cru" por causa dos placeholders.
Valide sempre com o script, que os resolve antes:

```bash
scripts/validate-openapi.sh
```

Saída esperada:

```
OpenAPI valido
  paths      : 36
  operacoes  : 49 (+36 OPTIONS de preflight)
  schemas    : 47
  integracoes: todas as operacoes possuem x-amazon-apigateway-integration
  path params: todos mapeados em requestParameters
```

## Executar HML

```bash
cd iac/environments/hml

cp terraform.tfvars.example terraform.tfvars   # ajuste tag da imagem e chaves JWT
terraform init

# Fase 1 — repositórios ECR (a Lambda usa imagem de container; ver README raiz)
terraform apply -target=module.stack.module.ecr_lambda -target=module.stack.module.ecr_app

# Fase 2 — imagem placeholder no ECR privado
ECR_URL=$(terraform output -raw lambda_ecr_repository_url)
bash ../../../scripts/lambda-bootstrap-image.sh "$ECR_URL" bootstrap

# Fase 3 — stack completo, incluindo API Gateway, NLB e VPC Link
terraform apply
```

Pela pipeline: **Actions → Terraform → `action: apply`, `env: hml`**. As três
fases são executadas automaticamente.

> O VPC Link leva de 5 a 10 minutos para ser criado. É o recurso mais lento.

Após o apply:

```bash
terraform output api_gateway_url          # URL base (já inclui /hml)
terraform output api_consumers            # consumidores habilitados
terraform output -json api_key_values | jq -r .web   # chave do consumidor web
terraform output app_backend_nlb_dns      # DNS do NLB interno
```

## Executar PRD

Idêntico, trocando o diretório:

```bash
cd iac/environments/prd
```

Nada mais muda. As diferenças entre ambientes estão nos arquivos
`config-PRD.yaml` e no sizing em `environments/prd/main.tf` — nunca em condicional
no código dos módulos.

## Consumir a API

```bash
BASE=$(terraform output -raw api_gateway_url)
KEY=$(terraform output -json api_key_values | jq -r .web)

# 1. Login (Lambda) — público, mas exige API key
TOKEN=$(curl -s -X POST "$BASE/autenticacao" \
  -H "x-api-key: $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"cpf":"12345678901","senha":"Senha@123"}' | jq -r .token)

# 2. Rota autenticada (EKS via VPC Link)
curl -s "$BASE/clientes/550e8400-e29b-41d4-a716-446655440000" \
  -H "x-api-key: $KEY" \
  -H "Authorization: Bearer $TOKEN"
```

Toda chamada precisa de `x-api-key`. Rotas autenticadas precisam também de
`Authorization: Bearer`.

## Consumidores e API keys

Cada consumidor declarado em `api-configuration/usage-plan/config-<ENV>.yaml`
ganha a **sua própria API key** ([ADR-009](../adr/ADR-009-multiplas-api-keys-por-consumidor.md)):

```yaml
consumers:
  web:
    description: Front-end web
    enabled: true
  mobile:
    description: Aplicativo mobile
    enabled: true
  ci:
    description: Contract test da pipeline
    enabled: true
    throttle: { rateLimit: 5, burstLimit: 10 }
    quota:    { limit: 1000, period: DAY }
```

Regra: quem **não** declara `throttle`/`quota` compartilha o usage plan do
ambiente; quem declara qualquer um dos dois ganha um usage plan dedicado, com os
campos omitidos herdando o padrão.

```bash
terraform output api_consumers                        # ["ci","mobile","web"]
terraform output -json api_key_values | jq -r .mobile # chave de um consumidor
terraform output -json api_key_values                 # todas
```

> `terraform output -raw api_key_values` **não** funciona: o output é um mapa.

**Revogar um consumidor** sem afetar os outros: `enabled: false` + `terraform apply`.

**Adicionar um consumidor:** nova entrada no YAML dos **dois** ambientes (os
nomes precisam bater entre HML e PRD; os limites não) + `terraform apply`.

## Usage Plan e throttling

Definidos em `api-configuration/usage-plan/config-<ENV>.yaml`.

Existem **duas camadas** de limite, que atuam juntas:

| Camada | Recurso AWS | Escopo | HML | PRD |
|---|---|---|---|---|
| Usage Plan | `aws_api_gateway_usage_plan` | por API key | 20 req/s, burst 40 | 100 req/s, burst 200 |
| Stage | `aws_api_gateway_method_settings` | API inteira | 50 req/s, burst 100 | 200 req/s, burst 400 |

O limite do stage é rede de segurança: mesmo que existam várias API keys, a API
como um todo não passa dele.

**Quota** (teto de volume, independente da taxa): 10.000 requisições/dia em HML,
200.000/mês em PRD. Estourar quota → `429 Too Many Requests`.

Fluxo de decisão do gateway:

```
requisição → API key válida? ─não→ 403
                  │sim
                  ▼
           dentro da quota? ─não→ 429
                  │sim
                  ▼
        dentro do throttle? ─não→ 429
                  │sim
                  ▼
             validação → backend
```

Para alterar um limite: editar o YAML e `terraform apply`. Não se toca em HCL.

As API keys são geradas a cada criação do ambiente e **não são versionadas**
([ADR-006](../adr/ADR-006-ambientes-efemeros-e-conta-educacional.md)).

### WAF rate-based (defesa por IP)

O usage plan limita **por API key**; não protege contra flood de quem não tem
key. Em **PRD** um AWS WAF rate-based fecha essa lacuna, bloqueando o IP que
passa de `waf.rateLimit` (2.000) requisições em 5 minutos. Configurado em
`usage-plan/config-PRD.yaml`:

```yaml
waf:
  enabled: true
  rateLimit: 2000
```

Em **HML** fica `enabled: false` (custo). A ordem completa das camadas de defesa
e os valores por ambiente estão na
[ADR-011](../adr/ADR-011-rate-limiting-defesa-em-camadas.md).

## CORS

Definido em `api-configuration/cors/config-<ENV>.yaml`.

**O gateway responde por duas partes; o backend pela terceira:**

| Situação | Quem responde | Como |
|---|---|---|
| Preflight `OPTIONS` | **gateway** | integração `mock` injetada em todos os 36 paths |
| Erros do gateway (403, 429, 400 de validação) | **gateway** | `aws_api_gateway_gateway_response` para `DEFAULT_4XX` / `DEFAULT_5XX` |
| Respostas reais 2xx | **backend** | precisa enviar `Access-Control-Allow-Origin` |

A terceira linha é uma limitação real do API Gateway: com integração *proxy*
(`http_proxy` / `aws_proxy`) o gateway **não consegue** injetar headers nas
respostas do backend. Por isso a aplicação e a Lambda precisam devolver
`Access-Control-Allow-Origin` coerente com o `allowOrigin` configurado.

Sem os headers nas respostas de erro (segunda linha), um 429 apareceria no
navegador como "CORS error" genérico em vez do erro real — daí os
`gateway_response`.

O preflight tem `security: []`: navegadores não enviam `x-api-key` no `OPTIONS`,
então exigir API key faria todo o CORS falhar.

Valores atuais: `allowOrigin: "*"` nos dois ambientes, porque ainda não existe
origem própria para o front. Fechar o CORS em PRD é editar **uma linha** em
`cors/config-PRD.yaml`.

## Autenticação e autorização

Duas camadas, com papéis distintos
([ADR-005](../adr/ADR-005-autorizacao-jwt-no-backend.md)):

| | Verifica | Onde |
|---|---|---|
| `x-api-key` | qual **aplicação** chama | gateway (API Key + Usage Plan) |
| `Authorization: Bearer <jwt>` | qual **usuário** e qual papel | backend (MicroProfile JWT) |

Por padrão **não há authorizer no gateway**: o JWT é emitido pela Lambda em
`POST /autenticacao` (RS256) e validado pelos backends. As chaves são injetadas em
runtime via `lambda_extra_env`, nunca versionadas.

### Authorizer de JWT na borda (opcional)

`enable_jwt_authorizer = true` liga um Lambda authorizer que valida o JWT antes
do backend ([ADR-007](../adr/ADR-007-lambda-authorizer-opcional.md)):

```bash
terraform apply -var="enable_jwt_authorizer=true"
```

Exige a chave pública RS256 — reusa `lambda_extra_env.MP_JWT_VERIFY_PUBLICKEY`
ou a variável `jwt_public_key`. Sem ela o apply falha com mensagem explícita, em
vez de subir uma API que rejeita tudo.

Ao ligar, as **44 operações** que declaram `bearerAuth` passam a exigir token
válido; as duas rotas de magic link e os preflights `OPTIONS` continuam abertos.
Nenhuma alteração no contrato é necessária — o `securityScheme` é templatizado.

| | Authorizer desligado (padrão) | Authorizer ligado |
|---|---|---|
| JWT inválido | chega ao backend, que devolve 401 | 401 na borda, sem invocar o backend |
| Custo | zero | 1 invocação por token novo a cada 5 min (cache) |
| `bearerAuth` no contrato | `http/bearer`, ignorado pelo gateway | `apiKey` + `x-amazon-apigateway-authorizer` |

O authorizer é escrito em **Go**, empacotado como binário nativo
(`provided.al2023`, arm64). A verificação RS256 usa a stdlib (`crypto/rsa`,
`crypto/x509`); a única dependência é a lib oficial `aws-lambda-go`. O apply
compila o binário via `build.sh` (exige Go). Testes na pipeline:

```bash
cd iac/modules/lambda-authorizer/src && go test ./...
```

### Rotas sem API key

| Rota | Motivo |
|---|---|
| `GET /ordem-servico/orcamento/aprovacao` | *magic link* aberto do e-mail; navegador não envia header customizado |
| `GET /ordem-servico/orcamento/reprovacao` | idem |
| `OPTIONS` de qualquer path | preflight não carrega headers customizados |

As duas primeiras são autorizadas pelo token dedicado na query string, que só o
cliente dono da OS recebe.

## Validação de request

O contrato declara um validador global:

```yaml
x-amazon-apigateway-request-validators:
  full:
    validateRequestBody: true
    validateRequestParameters: true
x-amazon-apigateway-request-validator: full
```

Com isso o gateway rejeita **antes de chegar ao backend**:

- body que não bate com o JSON Schema (campo obrigatório ausente, tipo errado,
  `minLength`, `minimum`, `enum` inválido);
- query/path parameter obrigatório ausente.

Os `components.schemas` do OpenAPI viram Models do API Gateway automaticamente na
importação — não é preciso declarar `aws_api_gateway_model`.

Limitação: o API Gateway valida com um subconjunto de JSON Schema Draft 4.
Palavras-chave do OpenAPI 3 como `nullable` e `format` são ignoradas na validação
(`format: uuid` **não** rejeita um valor mal formatado). Validação semântica
continua sendo responsabilidade do backend.

## Integração com os backends

| Rotas | Tipo | Destino |
|---|---|---|
| `POST /autenticacao`, `POST /autenticacao/reset-senha` | `aws_proxy` | Lambda de autenticação |
| Outras 47 operações | `http_proxy` + `VPC_LINK` | aplicação no EKS |

Caminho até o EKS:

```
API Gateway → VPC Link → NLB interno (:80) → NodePort 30080 → Service → pods
```

### Contrato com os manifestos do Kubernetes

> O `Service` da aplicação precisa ser `type: NodePort` com `nodePort: 30080`.

É o único acoplamento entre este repositório e o de manifestos. O valor é
`var.app_node_port` em `modules/stack`. Se divergir, o target group fica
*unhealthy* e o gateway responde 503 — o apply não falha.

O health check do target group é **TCP** por padrão, para não depender de rota de
health específica do framework. Para usar HTTP:

```hcl
app_health_check_protocol = "HTTP"
app_health_check_path     = "/actuator/health"   # ou /q/health
```

## Observabilidade

Com `enable_api_access_logs = true` (padrão):

- **Access log** em `/aws/apigateway/servicetrack-<env>-api/<env>`, formato JSON
  com `requestId`, `ip`, `httpMethod`, `path`, `status`, `integration.error` e
  `apiKeyId`.
- **Execution log** no nível definido por `loggingLevel` (`INFO` em HML,
  `ERROR` em PRD).
- **Métricas** do CloudWatch por método em HML (`detailedMetrics: true`);
  desligadas em PRD por custo.

Depende de uma role de CloudWatch no nível da conta
(`aws_api_gateway_account`, usando a `LabRole`). Se a conta educacional não
permitir, desligue — a API continua funcional:

```bash
terraform apply -var="enable_api_access_logs=false"
```

## Contract testing

Duas camadas ([ADR-010](../adr/ADR-010-contract-testing-na-pipeline.md)).

### Estática — todo push/PR, sem AWS

`.github/workflows/contract.yml` roda três jobs:

- validação do `openApi.yaml` (schema, integrações presentes, path params
  mapeados) e consistência entre `config-HML.yaml` e `config-PRD.yaml`;
- testes do authorizer de JWT;
- `terraform fmt -check` e `validate` nos dois ambientes.

Localmente:

```bash
scripts/validate-openapi.sh
( cd iac/modules/lambda-authorizer/src && go test ./... )
```

### Dinâmica — após cada apply

`scripts/contract-test.sh` bate na API publicada. **Nenhuma asserção depende do
backend estar de pé** — todas as respostas esperadas vêm do próprio gateway:

```bash
BASE=$(terraform output -raw api_gateway_url)
KEY=$(terraform output -json api_key_values | jq -r .ci)
REST_API_ID=$(terraform output -raw api_gateway_id) STAGE_NAME=hml \
  scripts/contract-test.sh "$BASE" "$KEY"
```

Verifica: preflight com headers de CORS, 403 sem API key, 403 com key inválida,
CORS nas respostas de erro, 400 de request validation (body e query param),
403 em rota inexistente e ausência de API key nos magic links.

Com `REST_API_ID` e `STAGE_NAME`, compara ainda as rotas publicadas na AWS
(`aws apigateway get-export`) com o contrato versionado — detecta drift causado
por mexida no console ou deployment atrasado.

Com `EXPECT_AUTHORIZER=true`, exige 401 em rota autenticada sem Bearer válido.

## Destruir e recriar

```bash
cd iac/environments/hml

# Libera LoadBalancers criados pelo Kubernetes (ArgoCD), senão a VPC não sai
bash ../../../scripts/aws-lb-cleanup.sh

terraform destroy
```

Recriar:

```bash
terraform apply -target=module.stack.module.ecr_lambda -target=module.stack.module.ecr_app
ECR_URL=$(terraform output -raw lambda_ecr_repository_url)
bash ../../../scripts/lambda-bootstrap-image.sh "$ECR_URL" bootstrap
terraform apply
```

Nenhum passo manual no console do API Gateway. Não há import, não há Usage Plan
criado à mão, não há CORS configurado na interface.

**Muda a cada recriação:** a URL (novo ID de API) e a API key. O DNS do NLB também
muda, mas é resolvido automaticamente — ele é injetado no contrato no apply.

## Alterar a API

### Adicionar ou mudar uma rota

1. Edite `apis/service-track-api-ext/openApi.yaml`.
2. Inclua `x-amazon-apigateway-integration` na operação (copie de uma rota
   equivalente).
3. Se a rota tiver path parameter, mapeie em `requestParameters`.
4. Adicione `options: ${cors_options}` no path, se for novo.
5. `scripts/validate-openapi.sh`
6. `terraform apply` — o trigger `sha1(body)` republica o deployment.

### Mudar throttling, quota ou CORS

Edite o YAML em `api-configuration/` e rode `terraform apply`.

### Mudar o backend de uma rota

Troque o bloco `x-amazon-apigateway-integration` da operação entre o modelo
`aws_proxy` (Lambda) e `http_proxy`+`VPC_LINK` (EKS). Nenhuma mudança em HCL.

## Troubleshooting

| Sintoma | Causa provável | Ação |
|---|---|---|
| `403 Forbidden` sem corpo | falta `x-api-key` ou chave desvinculada do plano | `terraform output -json api_key_values \| jq -r .web` |
| `401 Unauthorized` com authorizer ligado | JWT ausente, expirado, mal assinado ou emissor divergente | ver log da função `<name>-jwt-authorizer` |
| 401 mesmo com token válido | chave pública rotacionada sem novo apply | `terraform apply` para atualizar a env var do authorizer |
| `429 Too Many Requests` | throttle ou quota | ver `usage-plan/config-<ENV>.yaml` |
| `503 Service Unavailable` nas rotas do EKS | target group unhealthy | conferir `nodePort: 30080` no Service e se os pods estão de pé |
| `500` com `integration.error` no access log | backend fora do ar ou path divergente | conferir o `uri` da integração |
| Navegador diz "CORS error" num erro qualquer | resposta 2xx do backend sem `Access-Control-Allow-Origin` | o backend precisa enviar o header |
| Apply falha em `aws_api_gateway_account` | `LabRole` não assumível por `apigateway.amazonaws.com` | `-var="enable_api_access_logs=false"` |
| Apply falha ao importar o body | contrato inválido | `scripts/validate-openapi.sh` |
| `terraform destroy` trava na VPC | ENIs de LoadBalancer do Kubernetes | `scripts/aws-lb-cleanup.sh` antes |
