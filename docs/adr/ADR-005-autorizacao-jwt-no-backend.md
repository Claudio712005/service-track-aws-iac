# ADR-005 — Sem authorizer no gateway: JWT continua no backend, API Key controla consumo

- **Status:** aceito
- **Data:** 2026-07-23

## Contexto

A API usa JWT RS256 emitido pela Lambda de autenticação (`POST /autenticacao`) e
validado pelos backends via MicroProfile JWT (`MP_JWT_VERIFY_ISSUER`,
`MP_JWT_VERIFY_PUBLICKEY`). As chaves são injetadas em runtime por
`lambda_extra_env` e nunca são versionadas.

O API Gateway REST oferece três formas de autorizar na borda:

1. **Cognito User Pool authorizer**
2. **Lambda authorizer** (TOKEN ou REQUEST)
3. **IAM / SigV4**

## Decisão

**Nenhum authorizer no gateway.** A validação do JWT permanece no backend.

Na borda, o gateway aplica **API Key + Usage Plan + throttling + quota +
request validation**.

## Justificativa

### Por que não Cognito

O emissor do token é a própria Lambda, não um User Pool. Um Cognito authorizer
validaria tokens de um emissor que não existe nesta arquitetura. Adotá-lo
significaria migrar a emissão de token para o Cognito — mudança de escopo grande,
que afetaria dois repositórios de aplicação, sem ganho para o objetivo do EXT.

### Por que não Lambda authorizer

Seria uma **segunda função Lambda**. A Lambda existente é `package_type = "Image"`
e sofre do problema ovo-e-galinha documentado no README: o ECR é criado pelo
mesmo Terraform que cria a função, exigindo apply em três fases com imagem
placeholder. Um authorizer traria exatamente esse ciclo de novo — mais um ECR,
mais um seed de imagem, mais um passo no CI — para **duplicar** uma validação que
o backend já faz corretamente.

Numa conta educacional com ambientes recriados a cada laboratório, cada fase extra
de bootstrap é um ponto a mais de falha.

### Por que API Key não substitui o JWT (e vice-versa)

São controles de camadas diferentes e ambos são necessários:

| | Responde | Granularidade |
|---|---|---|
| **API Key** | *qual aplicação cliente* está chamando | por consumidor — habilita throttling e quota |
| **JWT** | *qual usuário* e com *qual papel* (CLIENTE/MECANICO) | por usuário — habilita autorização de domínio |

A API Key não identifica usuário e não deve ser tratada como segredo forte: ela
viaja no front-end. O JWT é que carrega identidade e papéis.

## `bearerAuth` no contrato

O `securitySchemes.bearerAuth` (`type: http, scheme: bearer`) foi **mantido** no
OpenAPI, mesmo o API Gateway não o interpretando. Motivo: ele é parte do contrato
técnico que o consumidor precisa cumprir — sem ele, o contrato diria que basta a
API Key, o que é falso.

Consequência prática: a importação do documento emite um *warning*
("unsupported security definition type"). Por isso
`aws_api_gateway_rest_api.fail_on_warnings = false`. Falhar no warning quebraria
o apply sem nenhum ganho de segurança.

## Rotas sem API Key

Duas rotas são exceção declarada, com `security: []`:

- `GET /ordem-servico/orcamento/aprovacao`
- `GET /ordem-servico/orcamento/reprovacao`

São *magic links* enviados por e-mail e abertos direto no navegador. **Não há como
o navegador enviar o header `x-api-key` ao clicar num link.** Exigir API Key aí
quebraria o fluxo de aprovação de orçamento.

A autorização dessas rotas é feita pelo token dedicado na query string, que só o
cliente dono da OS recebe — mecanismo já implementado na aplicação.

O `OPTIONS` de preflight também tem `security: []`: navegadores não enviam headers
customizados no preflight, e exigir API Key faria todo CORS falhar com 403.

## Consequências

- Um token JWT vazado continua sendo suficiente para chamar a API — o gateway não
  o inspeciona. O modelo de ameaça não mudou em relação ao estado anterior.
- A quota do Usage Plan é por **API Key**, portanto por aplicação cliente, não por
  usuário final. Quota por usuário exigiria authorizer.
- Se no futuro for necessário barrar token inválido antes do backend, o caminho é
  um Lambda authorizer REQUEST — aceitando o custo de bootstrap descrito acima.
