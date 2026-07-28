# service-track-aws-iac

Infraestrutura como código (Terraform) do ambiente AWS da aplicação ServiceTrack.
Provisiona rede, cluster Kubernetes gerenciado (EKS), repositórios de imagem (ECR),
GitOps (ArgoCD), o serviço de autenticação em AWS Lambda (Quarkus/Kotlin) e a
exposição externa da API por API Gateway.

> **O banco de dados não vive mais aqui.** O RDS foi para
> [service-track-db-infra](https://github.com/Claudio712005/service-track-db-infra),
> junto com o orçamento de conexões e as roles de runtime (`DB-ADR-003`).
> Este repositório lê endpoint, credenciais e tamanhos de pool do SSM, e cria as
> regras de entrada na porta 5432 do security group do banco.

O código é organizado em módulos reutilizáveis e dois ambientes isolados,
homologação (`hml`) e produção (`prd`), cada um com seu próprio state e sizing.

## Estrutura

```
apis/
  service-track-api-ext/           Contrato de exposicao externa (EXT) da API
    openApi.yaml                   Definicao do API Gateway (importada pelo Terraform)
    api-configuration/
      cors/config-{HML,PRD}.yaml       CORS por ambiente
      usage-plan/config-{HML,PRD}.yaml Throttling, quota, consumidores e logs

iac/
  network/
    hml/ prd/      VPC e subnets - state proprio, PRIMEIRA fase de cada ambiente
  bootstrap/
    dns/           Hosted zone Route53 - PERSISTENTE, state proprio, aplicada uma vez
  modules/
    network/       VPC, subnets publicas/privadas, IGW, NAT, rotas
    eks/           Cluster EKS + node group
    addons/        ArgoCD e metrics-server (Helm)
    ecr/           Repositorio de imagem (reutilizavel)
    lambda/        Lambda de autenticacao (imagem de container) + SG + logs
    lambda-authorizer/ Authorizer de JWT na borda (Go, provided.al2023) + testes
    vpc-link/      NLB interno + VPC Link (API Gateway -> EKS)
    api-gateway/   REST API a partir do openApi.yaml, usage plans, API keys,
                   CORS, dominio customizado
    stack/         Composicao que liga todos os modulos acima
  environments/
    hml/           Homologacao (t3.small / db.t3.micro) - state key servicetrack/hml
    prd/           Producao   (t3.large / db.t3.medium) - state key servicetrack/prd

docs/
  adr/             Decisoes arquiteturais (ADR-001 a ADR-010)
  rfc/             RFC-001: arquitetura de exposicao da API
  api-gateway/     Guia tecnico e operacional do gateway

.github/workflows/
  network.yml        Aplica a rede do ambiente (manual) - primeira fase
  contract.yml       Valida contrato + authorizer + fmt/validate (push e PR)
  terraform.yml      plan / apply / destroy por ambiente (manual)
  dns-bootstrap.yml  Cria a hosted zone persistente e imprime os NS (manual)
  dns-publish.yml    Publica o dominio em PRD apos a delegacao (manual)
```

Cada ambiente é um root module fino: configura os providers, define o backend S3
(com key própria por ambiente) e chama o módulo `stack` passando o sizing daquele
ambiente.

## Recursos provisionados

- **Rede** (`modules/network`) — VPC em duas AZs, com subnets públicas e privadas,
  Internet Gateway, NAT Gateway e tabelas de rota. As subnets têm as tags exigidas
  pelo EKS para descoberta de load balancers.
- **EKS** (`modules/eks`) — cluster gerenciado com endpoint público e node group nas
  subnets privadas. Usa a role `LabRole` da conta (ambiente educacional AWS).
- **Addons** (`modules/addons`) — ArgoCD e metrics-server via Helm. O metrics-server
  habilita o HPA; o ArgoCD pode ser exposto por LoadBalancer (`argocd_expose_lb`).
- **Banco** — provisionado em outro repositório. Este stack lê `endpoint`, `port`,
  `name`, `username`, `password`, `security-group-id` e os tamanhos de pool de
  `/servicetrack/<env>/db/*` no SSM, e cria as regras de entrada na porta 5432 do
  security group do banco a partir dos nodes do EKS e da Lambda.
- **ECR** (`modules/ecr`) — repositórios de imagem: um para a aplicação (deploy no
  EKS) e um para a Lambda de autenticação.
- **Lambda** (`modules/lambda`) — função de autenticação empacotada como imagem de
  container (Quarkus + Kotlin, `package_type = "Image"`). Roda dentro da VPC, nas
  subnets privadas, para alcançar o RDS. As credenciais do banco e a configuração
  JWT são injetadas por variáveis de ambiente.
- **VPC Link** (`modules/vpc-link`) — NLB interno nas subnets privadas, com o Auto
  Scaling Group do node group registrado no target group, mais o VPC Link que
  liga o API Gateway a esse NLB. É o caminho privado do gateway até a aplicação
  no EKS.
- **API Gateway** (`modules/api-gateway`) — REST API construída a partir de
  `apis/service-track-api-ext/openApi.yaml`. Roteia `/autenticacao*` para a Lambda
  (`AWS_PROXY`) e as demais rotas para a aplicação no EKS (`HTTP_PROXY` via VPC
  Link). Provisiona também stage, deployment, Usage Plan, API Key, CORS e logs.

## Exposição da API (EXT)

O contrato em `apis/service-track-api-ext/openApi.yaml` **é** a definição do
gateway: o Terraform o importa em `aws_api_gateway_rest_api.body`, injetando em
tempo de apply o ARN da Lambda, o DNS do NLB e o ID do VPC Link.

```
Internet -> API Gateway REST (stage hml|prd)
              |-- /autenticacao*  -> Lambda de autenticacao
              |-- demais rotas    -> VPC Link -> NLB interno -> NodePort 30080 -> EKS
```

Na borda o gateway aplica API Key por consumidor (`x-api-key`), throttling, quota,
validação de request por JSON Schema e CORS.

A aplicação **só aceita requisição vinda do gateway** ([ADR-017](docs/adr/ADR-017-acesso-a-aplicacao-apenas-pelo-gateway.md)):
o gateway injeta `x-origem-gateway` em todas as integrações e a aplicação recusa com `403` quem
não o traz, exceto nos caminhos de plataforma usados pelos probes. O NodePort, por sua vez,
aceita tráfego apenas do security group do NLB.

O link de aprovação de orçamento enviado por e-mail aponta para o gateway, não para a
aplicação: `SERVICETRACK_API_BASE_URL` vem de `/servicetrack/<env>/api/base-url` no SSM, que
recebe o domínio customizado quando existe e o endpoint `execute-api` caso contrário. Em PRD
com domínio o link é estável; em HML ele muda a cada recriação do ambiente. A validação do JWT fica no backend
por padrão, e opcionalmente também na borda (`enable_jwt_authorizer`). O endpoint
pode ser publicado em domínio próprio com base path `/service-track/v1`
(`custom_domain`).

O DNS do domínio próprio fica numa hosted zone Route53 **persistente**
(`iac/bootstrap/dns`), fora do state dos ambientes: o alvo do API Gateway muda a
cada recriação, então a zona precisa sobreviver ao `destroy` para que o alias seja
refeito sem passo manual. A delegação no Registro.br é feita uma única vez.

Antes de qualquer `apply` que altere o contrato:

```bash
scripts/validate-openapi.sh
( cd iac/modules/lambda-authorizer/src && go test ./... )
```

As duas checagens rodam automaticamente em push/PR
(`.github/workflows/contract.yml`), e `scripts/contract-test.sh` valida a API
publicada após cada apply.

> O `Service` da aplicação no EKS precisa ser `type: NodePort` com
> `nodePort: 30080` (`var.app_node_port`). É o único acoplamento com o
> repositório de manifestos.

Guia completo em [`docs/api-gateway/README.md`](docs/api-gateway/README.md).
Índice das decisões em [`docs/README.md`](docs/README.md).

## Secrets e credenciais

Nenhum material sensível é versionado ([ADR-013](docs/adr/ADR-013-chaves-jwt-fora-do-git.md)).
Esta é a lista completa do que precisa existir e como criar.

| Segredo | Onde vive | Quando criar | Origem |
|---|---|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | GitHub → **este repo** → Environments `hml` e `prd` | a cada laboratório | AWS Academy → AWS Details → AWS CLI |
| `IAC_REPO_TOKEN` | GitHub → **repo da API** → Secrets | uma vez | PAT fino / GitHub App, `contents: write` só neste repo |
| `lambda_extra_env` (`MP_JWT_VERIFY_PUBLICKEY`, `SMALLRYE_JWT_SIGN_KEY`) | variável Terraform (tfvars / `TF_VAR`) | por ambiente | `openssl` (par RS256) |
| `app_secret_params` (`service-track-secret`, `db-init-creds`, `jwt-private`, `jwt-public`) | variável Terraform → SSM → secret do k8s | por ambiente | `openssl` + compor dotenv |

O material sensível entra como **variável Terraform** e é reaplicado a cada
recriação — guarde num `terraform.tfvars` local (gitignored) ou em `TF_VAR_*`.
A esteira Terraform transporta apenas as credenciais AWS, a tag da imagem e o
domínio; os segredos são fornecidos no `apply` (local, ou adicionando os
`TF_VAR_*` ao job).

### 1. Credenciais AWS (esteiras)

As três secrets por environment, renovadas a cada lab. Passo a passo em
[Antes de qualquer esteira](#antes-de-qualquer-esteira-renovar-as-credenciais-da-aws).

### 2. Token cross-repo (`IAC_REPO_TOKEN`)

Usado pelo repo da API para disparar o bump de imagem neste repo (ver
[Repositório da API](#repositório-da-api-cd-da-imagem)).

- GitHub → **Settings → Developer settings → Fine-grained tokens**.
- **Repository access:** apenas `service-track-aws-iac`.
- **Permissions → Repository → Contents: Read and write**. Nada além disso.
- Guarde no **repo da API** como secret `IAC_REPO_TOKEN`.

Se vazar, o dano máximo é um commit de bump (revertível) — não dá acesso à AWS.

### 3. Chaves JWT (RS256)

Um par assina/verifica o JWT. Gere com:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out privateKey.pem
openssl rsa -in privateKey.pem -pubout -out publicKey.pem
```

O mesmo par abastece dois consumidores:

- **Lambda de autenticação** — via `lambda_extra_env` (ver
  [Configuração da Lambda](#configuração-da-lambda-de-autenticação)):
  `MP_JWT_VERIFY_PUBLICKEY` = conteúdo de `publicKey.pem`,
  `SMALLRYE_JWT_SIGN_KEY` = conteúdo de `privateKey.pem`.
- **Aplicação no EKS** — via `app_secret_params` (`jwt-private` / `jwt-public`).

### 4. Segredos da aplicação (`app_secret_params`)

Um `map(string)` com quatro chaves conhecidas. O Terraform grava cada uma como
`SecureString` no SSM (`/servicetrack/<env>/<chave>`) e o
`scripts/app-secrets-bootstrap.sh` as materializa como secrets do Kubernetes no
cluster durante o `apply`.

| Chave | Vira o secret k8s | Formato | Conteúdo |
|---|---|---|---|
| `service-track-secret` | `service-track-secret` | dotenv | `APP_DB_USER`, `APP_DB_PASSWORD`, `FLYWAY_DB_USER`, `FLYWAY_DB_PASSWORD`, `UNSPLASH_CHAVE_ACESSO`, `RESEND_API_KEY` |
| `db-init-creds` | `db-init-creds` | dotenv | credenciais lidas por `kubernetes/k8s/overlays/local/scripts/01-init-roles.sh` (superusuário do RDS + roles `APP_DB_*` e `FLYWAY_DB_*`) |
| `jwt-private` | `service-track-jwt` (`privateKey.pem`) | PEM | `privateKey.pem` |
| `jwt-public` | `service-track-jwt` (`publicKey.pem`) | PEM | `publicKey.pem` |

Exemplo no `terraform.tfvars` (gitignored):

```hcl
app_secret_params = {
  "service-track-secret" = <<-EOT
    APP_DB_USER=app_user
    APP_DB_PASSWORD=troque_isto
    FLYWAY_DB_USER=flyway_user
    FLYWAY_DB_PASSWORD=troque_isto
    UNSPLASH_CHAVE_ACESSO=...
    RESEND_API_KEY=...
  EOT
  "db-init-creds" = <<-EOT
    POSTGRES_USER=servicetrack
    POSTGRES_PASSWORD=<master do RDS>
    POSTGRES_DB=servicetrack
    APP_DB_USER=app_user
    APP_DB_PASSWORD=troque_isto
    FLYWAY_DB_USER=flyway_user
    FLYWAY_DB_PASSWORD=troque_isto
  EOT
  "jwt-private" = file("privateKey.pem")
  "jwt-public"  = file("publicKey.pem")
}
```

Vazio (padrão), o passo é ignorado e nenhum secret é criado — a aplicação sobe
mas os pods ficam sem os segredos até você fornecê-los.

> Requer que a `LabRole` permita `ssm:PutParameter` e `ssm:GetParameter`. Se não
> permitir, entregue os secrets do k8s manualmente.

### Dev local (kind)

`scripts/gen-local-jwt-keys.sh` gera as chaves; o overlay `local` cria os demais
secrets com valores placeholder. Ver
[kubernetes/README.md](kubernetes/README.md).

## Repositório da API (CD da imagem)

O **código da aplicação** vive em outro repositório
([service-track-api](https://github.com/Claudio712005/service-track-api)). O
deploy da imagem é dirigido de lá ([ADR-015](docs/adr/ADR-015-cd-imagem-por-ambiente.md)):

```
repo da API: push → build → push no ECR (servicetrack-<env>-app, tag = commit SHA)
                                   │ repository_dispatch (image-published)
                                   ▼
este repo: deploy-image.yml → reescreve newTag do overlay → commit em main
                                   │
                                   ▼
             ArgoCD sincroniza → novo Deployment
```

A esteira da API precisa de:

1. Credenciais AWS para `docker push` no ECR do ambiente
   (`servicetrack-hml-app` / `servicetrack-prd-app`).
2. Tag da imagem = **commit SHA** (o repo ECR é `IMMUTABLE`).
3. O secret `IAC_REPO_TOKEN` (item 2 acima) e, ao fim do push, o dispatch:

   ```yaml
   - uses: peter-evans/repository-dispatch@v3
     with:
       token: ${{ secrets.IAC_REPO_TOKEN }}
       repository: Claudio712005/service-track-aws-iac
       event-type: image-published
       client-payload: '{"environment":"prd","image_tag":"${{ github.sha }}"}'
   ```

O gate de vulnerabilidade (scan do ECR) é responsabilidade da CI da API: cheque
os *findings* antes de disparar o dispatch
([ADR-016](docs/adr/ADR-016-seguranca-supply-chain.md)). Este repo só recebe a
tag já aprovada.

> No primeiro deploy de um ambiente a imagem ainda não existe no ECR: os pods
> ficam em `ImagePullBackOff` até o primeiro `image-published`.

## Deploy pela pipeline

Toda a operação de **infraestrutura** é feita pelas esteiras do GitHub Actions
(**Actions → escolha a esteira → Run workflow**). São seis:

| Esteira | Quando |
|---|---|
| **Network** | manual — **primeira fase** de qualquer ambiente, antes do banco |
| **Contract** | automática, em push/PR que toca o contrato ou os módulos do gateway |
| **Terraform** | manual — `plan`, `apply` ou `destroy` de um ambiente |
| **Deploy image (bump)** | disparada pelo repo da API — atualiza a tag da imagem |
| **DNS (zona persistente)** | manual — uma vez, para criar a hosted zone |
| **DNS (publicar dominio em PRD)** | manual — depois de configurar o Registro.br |

---

## Ordem de subida de um ambiente

Os ambientes são efêmeros e esta ordem vale para **toda** recriação. Ela existe porque o
banco precisa da VPC para nascer, e este stack precisa do banco (`DB-ADR-003`).

| # | Repositório | Esteira | O quê |
|---|---|---|---|
| 1 | este | **Network** → `apply` | VPC e subnets |
| 2 | `service-track-db-infra` | **Terraform** → `apply` | RDS, parameter group, SSM |
| 3 | este | **Terraform** → `apply` | EKS, Lambda, gateway, ingress no SG do banco |
| 4 | `service-track-db-infra` | `scripts/aplicar-roles.sh` | roles `flyway_user` e `app_user` |

A esteira **Terraform** confere as fases 1 e 2 antes de começar e falha com mensagem
explícita apontando o que rodar antes, em vez de quebrar com erro de atributo inexistente.

**Destruir é a ordem inversa:** stack → banco → rede. Destruir a rede com banco de pé deixa
recursos órfãos e o `destroy` da VPC falha.

### Antes de qualquer esteira: renovar as credenciais da AWS

A conta é AWS Academy: **as credenciais mudam a cada laboratório novo** e as
esteiras falham com `ExpiredToken` se estiverem velhas. Atualize antes de rodar
qualquer coisa.

1. Inicie o laboratório na AWS Academy e abra **AWS Details → AWS CLI**.
2. Copie os três valores (`aws_access_key_id`, `aws_secret_access_key`,
   `aws_session_token`).
3. No GitHub: **Settings → Secrets and variables → Actions → Secrets**, atualize
   nos dois environments (`hml` e `prd`):

   | Secret | Origem |
   |---|---|
   | `AWS_ACCESS_KEY_ID` | AWS Details |
   | `AWS_SECRET_ACCESS_KEY` | AWS Details |
   | `AWS_SESSION_TOKEN` | AWS Details |

> Se um `apply` falhar logo no `terraform init` com erro de credencial ou token
> expirado, é quase sempre isso.

---

### Deploy de HML

HML é o ambiente enxuto: **sem domínio próprio, sem LoadBalancer do ArgoCD e sem
métricas detalhadas do CloudWatch**, para liberar orçamento para observabilidade.

**Pré-requisitos:**

1. Secrets da AWS renovados (acima).
2. Segredos da aplicação e da Lambda fornecidos como variáveis Terraform, se você
   quer a aplicação funcional — ver [Secrets e credenciais](#secrets-e-credenciais).
   Sem eles, a infraestrutura sobe, mas a app fica sem JWT/DB.

1. **Actions → Terraform → Run workflow**
   - `action`: `apply`
   - `env`: `hml`
   - `lambda_image_tag`: tag da imagem no ECR (ou `bootstrap` na primeira vez)
   - `custom_domain`: irrelevante em HML, é ignorado
2. Acompanhe o run. O apply executa sozinho as três fases da Lambda
   (ECR → imagem placeholder → stack completo) e, ao final, roda o contract test.
3. No **summary** do run estão a URL da API e o comando para ler as API keys.

A API responde em `https://<id>.execute-api.us-east-1.amazonaws.com/hml`.
**Essa URL muda a cada recriação** — leia sempre do output.

Acesso ao ArgoCD em HML (não há LoadBalancer):

```bash
aws eks update-kubeconfig --name servicetrack-hml --region us-east-1
kubectl -n argocd port-forward svc/argocd-server 8080:80
# http://localhost:8080
```

---

### Deploy de PRD

PRD é o único ambiente que usa o domínio `clausilva.com.br`.

**Pré-requisitos:**

1. Secrets da AWS renovados.
2. Segredos da aplicação e da Lambda (ver [Secrets e credenciais](#secrets-e-credenciais)).
3. **DNS configurado** — só na primeira vez, ou se a hosted zone for recriada.
   Detalhado na próxima seção.

Com o DNS já delegado, o deploy é igual ao de HML:

1. **Actions → Terraform → Run workflow**
   - `action`: `apply`
   - `env`: `prd`
   - `custom_domain`: `auto` (padrão) — liga o domínio se a delegação já existir
2. Ao final, a API responde em
   `https://api.clausilva.com.br/service-track/v1`.

`custom_domain` aceita ainda `off` (força sem domínio, útil para subir rápido) e
`on` (força com domínio; falha se a delegação não existir).

---

### Configuração do DNS de PRD (uma única vez)

O Registro.br **não expõe API** para gerenciar a zona, então esta parte não tem
como ser automatizada. Por isso ela vive em esteiras separadas e só precisa ser
feita uma vez.

O motivo de existir uma zona Route53 no meio: o API Gateway publica um alvo
`d-<aleatório>.execute-api...` **regerado a cada recriação de PRD**. Com o DNS
apenas no Registro.br, cada `destroy`/`apply` exigiria editar o registro à mão.
Com a zona no Route53, o Terraform refaz o alias sozinho.

**Passo 1 — criar a zona**

**Actions → DNS (zona persistente) → Run workflow**
- `action`: `apply`
- `registered_domain`: `clausilva.com.br`
- `subdomain`: `api`

O summary do run imprime os quatro name servers.

**Passo 2 — delegar no Registro.br** *(manual)*

Em **registro.br → Painel → clausilva.com.br → DNS**, no **modo avançado**,
adicione uma entrada por name server:

| TIPO | NOME | DADOS |
|---|---|---|
| NS | `api` | `ns-xxx.awsdns-xx.com` |
| NS | `api` | `ns-xxx.awsdns-xx.net` |
| NS | `api` | `ns-xxx.awsdns-xx.org` |
| NS | `api` | `ns-xxx.awsdns-xx.co.uk` |

Clique em **SALVAR ALTERAÇÕES**.

> Delegue apenas o subdomínio `api`. **Não** delegue o apex `clausilva.com.br`:
> os registros MX, SPF e DKIM do e-mail (Resend/SES) ficam no Registro.br e
> parariam de responder.

Confirme a propagação (leva de minutos a horas):

```bash
dig +short NS api.clausilva.com.br
```

Deve responder os quatro NS da AWS. Enquanto responder vazio, ainda não propagou.

**Passo 3 — publicar o domínio**

**Actions → DNS (publicar dominio em PRD) → Run workflow**

Essa esteira confere a delegação, emite o certificado ACM, cria o domínio e o
alias, e roda o contract test contra a URL final. Se a delegação ainda não
estiver ativa, ela para com erro claro em vez de pendurar até o timeout do ACM.

**Pronto.** A partir daí o Registro.br não é mais tocado: os próximos applies de
PRD detectam a delegação sozinhos (`custom_domain: auto`) e mantêm o domínio,
mesmo depois de `destroy` + `apply`.

> **Nunca** rode a esteira DNS com intenção de destruir a zona. Perder a zona
> significa refazer a delegação no Registro.br e esperar a propagação de novo.

---

### Destruir um ambiente

**Actions → Terraform → Run workflow** com `action: destroy` e o `env` desejado.
A esteira limpa antes os LoadBalancers órfãos criados pelo Kubernetes.

A hosted zone **não** é destruída: ela vive em outro state
(`servicetrack/bootstrap-dns`).

## Pré-requisitos

- Terraform >= 1.10.0
- AWS CLI configurado com credenciais válidas
- `kubectl` e `helm` para operar o cluster após o provisionamento
- Docker (para buildar e publicar a imagem da Lambda)
- Go >= 1.23 — só quando `enable_jwt_authorizer = true`, pois o apply compila o
  authorizer (o CI resolve com `actions/setup-go`)
- Bucket S3 do backend já existente (ver `environments/<env>/versions.tf`)

## Ordem de provisionamento da Lambda (bootstrap)

A Lambda usa `package_type = "Image"` e imagens de container do Lambda só podem vir de
um **ECR privado** da própria conta. Como o ECR é criado pelo mesmo Terraform, existe
um problema de ovo-e-galinha no primeiro apply. A solução é fazer o apply em fases,
usando uma imagem placeholder:

1. Cria os repositórios ECR.
2. Publica uma imagem placeholder (`:bootstrap`) no ECR da Lambda — puxa a base pública
   `public.ecr.aws/lambda/java:21` e re-publica no ECR privado.
3. Apply completo: a função é criada a partir de `:bootstrap`.
4. O **código real** é entregue depois, fora do Terraform, via
   `aws lambda update-function-code` (feito no CI do repositório
   [service-track-lambda](https://github.com/Claudio712005/service-track-lambda)).

O módulo da Lambda tem `lifecycle { ignore_changes = [image_uri] }`, então o Terraform
gerencia a **infra** da função, não o **código**. Redeploys de código não exigem
`terraform apply` — importante na conta de estudante, cujo login muda a cada laboratório.

Na pipeline, o job de apply executa essas fases automaticamente. Manualmente:

```bash
cd iac/environments/hml   # ou prd
terraform init

# Fase 1: repositorios ECR
terraform apply -target=module.stack.module.ecr_lambda -target=module.stack.module.ecr_app

# Fase 2: imagem placeholder no ECR privado
ECR_URL=$(terraform output -raw lambda_ecr_repository_url)
bash ../../../scripts/lambda-bootstrap-image.sh "$ECR_URL" bootstrap

# Fase 3: stack completo
terraform apply

# Deploy do codigo real (normalmente feito pelo CI da Lambda):
aws lambda update-function-code \
  --function-name servicetrack-hml-auth \
  --image-uri "$ECR_URL:<tag-da-imagem-real>"
```

## Uso

Cada ambiente é aplicado de forma independente, a partir do seu diretório:

```bash
cd iac/environments/prd

cp terraform.tfvars.example terraform.tfvars   # ajuste tag da imagem e chaves JWT

terraform init
terraform plan
terraform apply
```

Após o `apply`, configure o acesso ao cluster com o output `configure_kubectl`:

```bash
aws eks update-kubeconfig --name servicetrack-prd --region us-east-1
```

### Diferenças entre ambientes

| Recurso            | hml           | prd            |
|--------------------|---------------|----------------|
| Nodes EKS          | `t3.small`    | `t3.large`     |
| Node group (min/desired/max) | 1 / 1 / 2 | 2 / 2 / 4 |
| RDS                | `db.t3.micro` | `db.t3.medium` |
| Storage RDS        | 20 GB         | 50 GB          |
| Memória da Lambda  | 512 MB        | 1024 MB        |
| VPC CIDR           | `10.10.0.0/16`| `10.20.0.0/16` |
| State (key S3)     | `servicetrack/hml` | `servicetrack/prd` |
| Domínio próprio    | não           | `api.clausilva.com.br` |
| LoadBalancer do ArgoCD | não (port-forward) | sim |
| Métricas detalhadas do API Gateway | não | não |
| Retenção de log do gateway | 3 dias | 14 dias |

**HML foi enxugado de propósito** para liberar orçamento para observabilidade
(Datadog). Os cortes, em ordem de impacto:

| Corte | Economia | Contrapartida |
|---|---|---|
| Métricas detalhadas do API Gateway desligadas | até ~US$ 100/mês | métricas agregadas por stage continuam, e são grátis |
| ArgoCD sem LoadBalancer | ~US$ 16/mês | acesso por `kubectl port-forward` |
| Sem domínio próprio | ~US$ 0 direto | URL do `execute-api` muda a cada recriação |
| Retenção de log 7 → 3 dias | centavos | menos janela de investigação |

Métrica detalhada é cobrada como métrica customizada do CloudWatch
(~US$ 0,30/métrica/mês). São 5 métricas por método e a API tem 85 métodos
(49 operações + 36 `OPTIONS`), então o teto passa de US$ 100/mês com cobertura
total de teste. Por isso está desligada nos **dois** ambientes.

Fora da camada da API, os maiores custos continuam sendo o control plane do EKS
(~US$ 73/mês por cluster), o NAT Gateway (~US$ 32/mês, já é único por VPC) e o
NLB do VPC Link (~US$ 16/mês, inevitável para integração privada com o EKS).
Destruir HML quando não estiver em uso é o corte mais eficaz de todos.

### Outputs principais

| Output | Descrição |
|---|---|
| `configure_kubectl` | Comando para configurar o kubeconfig |
| `app_ecr_repository_url` | URL do repositório ECR da aplicação |
| `lambda_ecr_repository_url` | URL do repositório ECR da Lambda |
| `rds_endpoint`, `rds_jdbc_url` | Endereço e URL JDBC do PostgreSQL |
| `db_password` | Senha do banco (sensível) |
| `api_gateway_url` | URL base pública da API, já com o stage |
| `api_gateway_id` | ID do REST API |
| `api_consumers` | Consumidores habilitados, cada um com sua API key |
| `api_key_values` | Mapa consumidor → API key, para o header `x-api-key` (sensível) |
| `api_custom_domain_url` | URL no domínio customizado, se habilitado |
| `app_backend_nlb_dns` | DNS do NLB interno que expõe a aplicação do EKS |
| `argocd_url` | URL do ArgoCD (se exposto) |
| `argocd_admin_password_cmd` | Comando para obter a senha inicial do admin |

A URL e a API key **mudam a cada recriação do ambiente** — leia-as dos outputs,
não as fixe em código de cliente:

```bash
terraform output api_gateway_url
terraform output -json api_key_values | jq -r .web
```

Habilitando o domínio customizado (`custom_domain`), a URL passa a ser estável.

## Configuração da Lambda de autenticação

As variáveis de ambiente do banco (`POSTGRES_*`) são injetadas automaticamente a
partir do RDS. A configuração JWT segue o repositório do serviço
([service-track-lambda](https://github.com/Claudio712005/service-track-lambda)):

- `MP_JWT_VERIFY_ISSUER` e `SERVICETRACK_JWT_EXPIRACAO_SEGUNDOS` têm valores padrão.
- As chaves RS256 devem ser entregues em runtime, nunca versionadas. Passe o conteúdo
  PEM pela variável `lambda_extra_env` (ex.: `MP_JWT_VERIFY_PUBLICKEY` e
  `SMALLRYE_JWT_SIGN_KEY`), preferencialmente via `TF_VAR_lambda_extra_env` na
  pipeline em vez de gravar em arquivo. Como gerar o par: ver
  [Secrets e credenciais](#secrets-e-credenciais).

## Scripts

O diretório `scripts/` contém utilitários operacionais (login AWS, limpeza de load
balancers antes do destroy, bootstrap e seed do app no EKS, demo de HPA). Alguns
assumem um layout de monorepo (`infra/terraform`, `infra/k8s`,
`software/service-track-api`) diferente deste repositório; ajuste os caminhos antes
de usá-los.

## Destruição

```bash
cd iac/environments/prd
terraform destroy
```

Se o cluster tiver LoadBalancers ativos (ArgoCD, apps), rode
`scripts/aws-lb-cleanup.sh` antes para liberar ELBs e ENIs órfãos e evitar que o
`destroy` falhe ao remover a VPC.
