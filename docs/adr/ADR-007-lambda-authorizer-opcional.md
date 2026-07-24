# ADR-007 — Lambda authorizer de JWT como recurso opcional

- **Status:** aceito
- **Data:** 2026-07-23
- **Revisa:** [ADR-005](ADR-005-autorizacao-jwt-no-backend.md)

## Contexto

O ADR-005 decidiu não colocar authorizer no gateway. A objeção principal não era
conceitual — era de **custo de bootstrap**: a Lambda existente é
`package_type = "Image"`, e um authorizer seguindo o mesmo padrão traria de volta
o ciclo ovo-e-galinha do ECR (criar repositório → publicar imagem placeholder →
apply completo), mais um passo no CI e mais um ponto de falha em cada recriação
de ambiente.

Essa objeção **desaparece se o authorizer não for uma imagem de container**.

## Decisão

Implementar o authorizer em **Go**, empacotado como **binário nativo no runtime
`provided.al2023` (arm64)**, controlado por `enable_jwt_authorizer`
(default `false`).

> **Revisão (2026-07-24):** a primeira versão foi em Python 3.12, também ZIP. Foi
> reescrita em Go para alinhar com a stack do projeto (Kotlin/Quarkus na Lambda de
> autenticação, Go como linguagem de ferramentas). A decisão de fundo — ZIP em vez
> de imagem — não mudou; o resto desta ADR reflete a versão Go.

## Justificativa

### Por que binário nativo resolve a objeção do ADR-005

| | Lambda de autenticação (imagem) | Authorizer (Go, ZIP) |
|---|---|---|
| Origem do artefato | ECR privado da conta | `go build` no próprio apply |
| Fases de apply | 3 (ECR → imagem → stack) | 1 |
| Precisa de VPC | sim (alcança o RDS) | não (só verifica assinatura) |
| Cold start | segundos | dezenas de ms (binário estático) |

O authorizer é criado no mesmo `terraform apply` do resto: um `null_resource`
roda `build.sh` (cross-compile `GOOS=linux GOARCH=arm64 CGO_ENABLED=0`), e um
`data.archive_file` empacota o binário `bootstrap` no ZIP. Não há seed de imagem,
não há repositório novo.

Custo: o apply passa a exigir **Go instalado** na máquina que aplica. Na conta
educacional isso é aceitável — Go é a linguagem de ferramentas do time — e o CI
resolve com `actions/setup-go`. O `null_resource` só dispara quando
`enable_jwt_authorizer=true`, então quem não usa o authorizer não precisa de Go.

### Por que a verificação usa só a stdlib do Go

Diferente do Python, onde verificar RS256 exigiria `PyJWT` + `cryptography` (com
extensão nativa que precisaria ser compilada para a arquitetura da Lambda), no Go
tudo está na biblioteca padrão:

- `crypto/x509` faz o parse da chave pública PEM — `ParsePKIXPublicKey` (SPKI) com
  fallback para `ParsePKCS1PublicKey`. **Sem parser DER escrito à mão.**
- `crypto/rsa.VerifyPKCS1v15` + `crypto/sha256` fazem a verificação da assinatura.

A única dependência externa é `github.com/aws/aws-lambda-go` (o runtime da Lambda),
que é Go puro, sem cgo e sem dependências transitivas de produção. É a biblioteca
oficial e idiomática — não há equivalente stdlib.

**Segurança criptográfica exige prova.** O módulo tem uma suíte em
`iac/modules/lambda-authorizer/src/main_test.go`, sem dependências externas (gera
as chaves com `crypto/rsa` no próprio teste), rodada na pipeline a cada push com
`go vet` + `go test` + build cross-compile. Cobre:

- token válido com chave SPKI e com chave PKCS#1;
- assinatura inválida, assinatura de outra chave, payload adulterado;
- **`alg: none` rejeitado**;
- **troca para HS256 rejeitada** (usar a chave pública como segredo HMAC é o
  ataque clássico de confusão de algoritmo);
- token expirado, token sem `exp`, emissor divergente, token malformado;
- formato do recurso na policy e contexto devolvido ao backend.

O algoritmo é travado em RS256 **antes** de qualquer verificação — o `alg` do
próprio token nunca decide como validá-lo.

### Por que continua desligado por padrão

1. Exige a chave pública RS256 disponível no ambiente. Ela já é entregue à Lambda
   de autenticação por `lambda_extra_env.MP_JWT_VERIFY_PUBLICKEY`, e o authorizer
   reusa a mesma — mas se ela não estiver configurada, ligar o authorizer
   derrubaria **toda** a API. Há uma `precondition` que falha o apply com mensagem
   explícita nesse caso.
2. O backend continua validando o JWT. O authorizer é defesa em profundidade,
   não substituição.
3. Mantém o comportamento default estável para quem já usa os ambientes.

## Como se integra ao contrato

Sem alterar nenhuma das 49 operações. O `securityScheme` `bearerAuth` é
templatizado (`${bearer_auth_scheme}`) e assume uma de duas formas:

| `enable_jwt_authorizer` | `bearerAuth` vira | Efeito |
|---|---|---|
| `false` | `type: http, scheme: bearer` | ignorado pelo gateway; contrato apenas |
| `true` | `type: apiKey, in: header, name: Authorization` + `x-amazon-apigateway-authorizer` | authorizer TOKEN aplicado |

Como as operações já declaram `security: [{ApiKeyAuth, bearerAuth}]`, ligar a
flag aplica o authorizer às **44 operações autenticadas** automaticamente. As
duas rotas de *magic link* (`security: []`) e os 36 preflights `OPTIONS`
continuam abertos — comportamento verificado no teste de renderização.

## Detalhes de implementação

- **Tipo TOKEN**, não REQUEST: a identidade vem só do header `Authorization`.
- **`identityValidationExpression: ^[Bb]earer [-_.A-Za-z0-9]+$`** — headers que
  não casam são rejeitados com 401 **sem invocar a Lambda**, o que reduz custo e
  bloqueia lixo antes de gastar invocação.
- **Cache de 300s** (`authorizerResultTtlSeconds`), chaveado pelo token. Por isso
  a policy devolve um recurso com wildcard (`.../{stage}/*/*`): restringir ao
  método exato faria o cache errar em toda chamada a outra rota.
- **Contexto** (`sub`, `email`, `roles`) é repassado ao backend, que pode usá-lo
  para log/tracing — mas continua validando o token por conta própria.
- A permissão de invocação usa `${execution_arn}/authorizers/*`, porque o
  authorizer é criado pela importação do OpenAPI e não existe como recurso
  Terraform referenciável.

## Consequências

- Com a flag ligada, um JWT inválido ou expirado é barrado na borda: 401 sem
  consumir capacidade do backend.
- Custo: uma invocação de Lambda por token novo a cada 5 minutos. Desprezível.
- Ponto de falha novo: se a chave pública rotacionar sem novo `apply`, o
  authorizer passa a rejeitar tokens válidos. A chave é variável de ambiente da
  função, então rotação exige apply.
- 401 emitido pelo authorizer é coberto pelo `gateway_response` de `DEFAULT_4XX`,
  portanto carrega headers de CORS.
