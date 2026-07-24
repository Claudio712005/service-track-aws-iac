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
      usage-plan/config-{HML,PRD}.yaml Throttling, quota e logs por ambiente

iac/
  modules/
    network/       VPC, subnets publicas/privadas, IGW, NAT, rotas
    eks/           Cluster EKS + node group
    addons/        ArgoCD e metrics-server (Helm)
    rds/           PostgreSQL + security group
    ecr/           Repositorio de imagem (reutilizavel)
    lambda/        Lambda de autenticacao (imagem de container) + SG + logs
    vpc-link/      NLB interno + VPC Link (API Gateway -> EKS)
    api-gateway/   REST API a partir do openApi.yaml + usage plan + API key
    stack/         Composicao que liga todos os modulos acima
  environments/
    hml/           Homologacao (t3.small / db.t3.micro) - state key servicetrack/hml
    prd/           Producao   (t3.large / db.t3.medium) - state key servicetrack/prd

docs/
  adr/             Decisoes arquiteturais (ADR-001 a ADR-006)
  rfc/             RFC-001: arquitetura de exposicao da API
  api-gateway/     Guia tecnico e operacional do gateway
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

Na borda o gateway aplica API Key (`x-api-key`), throttling, quota, validação de
request por JSON Schema e CORS. A validação do JWT permanece no backend.

Antes de qualquer `apply` que altere o contrato:

```bash
scripts/validate-openapi.sh
```

> O `Service` da aplicação no EKS precisa ser `type: NodePort` com
> `nodePort: 30080` (`var.app_node_port`). É o único acoplamento com o
> repositório de manifestos.

Guia completo em [`docs/api-gateway/README.md`](docs/api-gateway/README.md).
Decisões arquiteturais em [`docs/adr/`](docs/adr/) e
[`docs/rfc/RFC-001`](docs/rfc/RFC-001-arquitetura-de-exposicao-da-api.md).

## Pré-requisitos

- Terraform >= 1.10.0
- AWS CLI configurado com credenciais válidas
- `kubectl` e `helm` para operar o cluster após o provisionamento
- Docker (para buildar e publicar a imagem da Lambda)
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
| `api_key_value` | API key do ambiente, para o header `x-api-key` (sensível) |
| `app_backend_nlb_dns` | DNS do NLB interno que expõe a aplicação do EKS |
| `argocd_url` | URL do ArgoCD (se exposto) |
| `argocd_admin_password_cmd` | Comando para obter a senha inicial do admin |

A URL e a API key **mudam a cada recriação do ambiente** — leia-as dos outputs,
não as fixe em código de cliente:

```bash
terraform output api_gateway_url
terraform output -raw api_key_value
```

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
