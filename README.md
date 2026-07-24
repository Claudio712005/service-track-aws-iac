# service-track-aws-iac

Infraestrutura como código (Terraform) do ambiente AWS da aplicação ServiceTrack.
Provisiona rede, cluster Kubernetes gerenciado (EKS), banco PostgreSQL (RDS),
repositórios de imagem (ECR), GitOps (ArgoCD), o serviço de autenticação em
AWS Lambda (Quarkus/Kotlin) e a exposição externa da API por API Gateway.

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
  bootstrap/
    dns/           Hosted zone Route53 - PERSISTENTE, state proprio, aplicada uma vez
  modules/
    network/       VPC, subnets publicas/privadas, IGW, NAT, rotas
    eks/           Cluster EKS + node group
    addons/        ArgoCD e metrics-server (Helm)
    rds/           PostgreSQL + security group
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
- **RDS** (`modules/rds`) — PostgreSQL privado, criptografado, com senha gerada
  aleatoriamente. Acesso na porta 5432 liberado apenas para os security groups
  autorizados (nodes EKS e Lambda).
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
validação de request por JSON Schema e CORS. A validação do JWT fica no backend
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

## Deploy pela pipeline

Toda a operação é feita pelas esteiras do GitHub Actions
(**Actions → escolha a esteira → Run workflow**). São quatro:

| Esteira | Quando |
|---|---|
| **Contract** | automática, em push/PR que toca o contrato ou os módulos do gateway |
| **Terraform** | manual — `plan`, `apply` ou `destroy` de um ambiente |
| **DNS (zona persistente)** | manual — uma vez, para criar a hosted zone |
| **DNS (publicar dominio em PRD)** | manual — depois de configurar o Registro.br |

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

**Pré-requisitos:** secrets da AWS renovados (acima). Nada além disso.

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
2. **DNS configurado** — só na primeira vez, ou se a hosted zone for recriada.
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
  pipeline em vez de gravar em arquivo.

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
