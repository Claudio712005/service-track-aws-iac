# ADR-010 — Contract testing em duas camadas na pipeline

- **Status:** aceito
- **Data:** 2026-07-23

## Contexto

O contrato virou a definição do gateway ([ADR-002](ADR-002-openapi-como-definicao-do-gateway.md)),
então um erro nele deixa de ser um problema de documentação e passa a ser um
`apply` quebrado — ou pior, uma API publicada com comportamento errado.

Riscos concretos:

1. Erro de sintaxe ou semântica no `openApi.yaml`. Já aconteceu: o arquivo estava
   inválido (`penapi:` em vez de `openapi:`) e ninguém percebeu porque nada o lia.
2. Operação sem `x-amazon-apigateway-integration` → método publicado sem backend.
3. Path param sem `requestParameters` → gateway chama o backend com o literal
   `{id}` na URL.
4. Regressão silenciosa: API key deixar de ser exigida, CORS parar de responder,
   validação de request desligar.
5. Drift entre o contrato versionado e o que está de fato publicado na AWS.

A pipeline anterior era `workflow_dispatch` apenas — nada rodava em push.

## Decisão

Duas camadas, com gatilhos diferentes:

| Camada | Quando | Precisa de AWS? | Onde |
|---|---|---|---|
| **Estática** | todo push/PR que toca `apis/`, os módulos do gateway ou os scripts | não | `.github/workflows/contract.yml` |
| **Dinâmica** | após cada `apply` | sim | job `apply` de `terraform.yml` |

## Camada estática

Workflow novo, separado do `terraform.yml` — que continua sendo
`workflow_dispatch` com `apply`/`destroy`. Misturar gatilhos de push num workflow
que destrói infraestrutura seria pedir acidente.

Três jobs:

- **`openapi`** — roda `scripts/validate-openapi.sh`, que resolve os placeholders
  do template com valores fake e valida o documento final. Além do schema
  OpenAPI, checa os riscos 2 e 3 acima: toda operação tem integração, todo path
  param tem mapeamento. Depois compara as chaves de `config-HML.yaml` e
  `config-PRD.yaml` — divergência estrutural quebra o build (nomes de consumidor
  precisam bater; limites podem divergir).
- **`authorizer`** — roda a suíte do authorizer de JWT
  ([ADR-007](ADR-007-lambda-authorizer-opcional.md)). É criptografia escrita à
  mão; não rodar os testes a cada push não é opção.
- **`terraform`** — `fmt -check` e `validate` nos dois ambientes, com
  `-backend=false` (sem credenciais).

O validador é rodado com o `bearer_auth_scheme` do **authorizer ligado**, que é a
forma mais complexa das duas — valida o caso mais arriscado.

## Camada dinâmica

`scripts/contract-test.sh <base_url> <api_key>`, executado após o apply com a key
do consumidor `ci`.

**Critério de desenho: nenhuma asserção pode depender do backend estar de pé.**
Os ambientes são efêmeros e a aplicação no EKS é entregue por ArgoCD, de forma
assíncrona ao Terraform. Um teste que exigisse o backend falharia por motivo
errado e seria desligado na primeira semana.

Todas as respostas esperadas são produzidas pelo próprio API Gateway:

| Asserção | O que prova |
|---|---|
| `OPTIONS /clientes` → 200 com `Access-Control-Allow-Origin` e `-Methods` | preflight mock publicado nos 36 paths |
| rota protegida sem `x-api-key` → 403 | API key sendo exigida |
| `x-api-key` inválida → 403 | key validada contra o usage plan |
| 403 traz headers de CORS | `gateway_response` de `DEFAULT_4XX` ativo |
| `POST /clientes` com body inválido → 400 | request validation contra o JSON Schema |
| `POST /autenticacao` com `{}` → 400 | validação de campo obrigatório |
| query param obrigatório ausente → 400 | `validateRequestParameters` ativo |
| rota inexistente → 403 | só as rotas do contrato existem |
| magic link **não** devolve 403 | exceção de API key preservada ([ADR-005](ADR-005-autorizacao-jwt-no-backend.md)) |

Com `EXPECT_AUTHORIZER=true`, verifica também 401 sem `Bearer` e 401 com token
inválido.

### Checagem de drift

Se `REST_API_ID` e `STAGE_NAME` estiverem no ambiente, o script exporta a
definição publicada (`aws apigateway get-export --export-type oas30`) e compara o
conjunto de paths com o do `openApi.yaml` versionado. Divergência = alguém mexeu
no console ou um deployment ficou para trás.

É a única asserção que precisa da AWS CLI; sem ela o script avisa e segue.

## Alternativas consideradas

- **Comparar o contrato do gateway com o OpenAPI gerado pela aplicação.** Seria o
  contract testing "de verdade" (provider × consumer), mas o contrato da aplicação
  vive em outro repositório e não é publicado em lugar estável. Ficou registrado
  como evolução na [RFC-001](../rfc/RFC-001-arquitetura-de-exposicao-da-api.md).
- **Schemathesis / Dredd** gerando casos a partir do OpenAPI. Exigiria backend de
  pé e traria dependência pesada para validar o que três `curl` já cobrem nesta
  camada.

## Consequências

- Push que quebra o contrato falha em ~1 minuto, sem tocar na AWS.
- O apply passa a falhar se a API subir sem API key, sem CORS ou sem validação —
  regressões que antes só apareceriam em uso.
- O consumidor `ci` precisa existir nos dois ambientes; a pipeline lê
  `api_key_values | jq -r '.ci'`. Removê-lo quebra o job de apply.
- O contract test não cobre o caminho até o EKS. Isso é intencional: aquele
  caminho depende do ArgoCD e é verificado pelo health check do target group.
