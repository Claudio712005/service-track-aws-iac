# service-track-aws-iac

Infraestrutura como código (Terraform) do ambiente AWS da aplicação ServiceTrack.
Provisiona rede, cluster Kubernetes gerenciado (EKS), banco PostgreSQL (RDS),
repositórios de imagem (ECR), GitOps (ArgoCD) e o serviço de autenticação em
AWS Lambda (Quarkus/Kotlin) exposto por API Gateway.

O código é organizado em módulos reutilizáveis e dois ambientes isolados,
homologação (`hml`) e produção (`prd`), cada um com seu próprio state e sizing.

## Estrutura

```
iac/
  modules/
    network/       VPC, subnets publicas/privadas, IGW, NAT, rotas
    eks/           Cluster EKS + node group
    addons/        ArgoCD e metrics-server (Helm)
    rds/           PostgreSQL + security group
    ecr/           Repositorio de imagem (reutilizavel)
    lambda/        Lambda de autenticacao (imagem de container) + SG + logs
    api-gateway/   HTTP API v2 -> Lambda
    stack/         Composicao que liga todos os modulos acima
  environments/
    hml/           Homologacao (t3.small / db.t3.micro) - state key servicetrack/hml
    prd/           Producao   (t3.large / db.t3.medium) - state key servicetrack/prd
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
- **API Gateway** (`modules/api-gateway`) — HTTP API v2 com integração proxy
  (`AWS_PROXY`) encaminhando todas as rotas para a Lambda, que resolve o roteamento
  interno via `quarkus-amazon-lambda-rest`.

## Pré-requisitos

- Terraform >= 1.10.0
- AWS CLI configurado com credenciais válidas
- `kubectl` e `helm` para operar o cluster após o provisionamento
- Docker (para buildar e publicar a imagem da Lambda)
- Bucket S3 do backend já existente (ver `environments/<env>/versions.tf`)

## Ordem de provisionamento da Lambda

A Lambda usa `package_type = "Image"`, então a imagem precisa existir no ECR antes do
`apply` que cria a função. O fluxo é:

```bash
cd iac/environments/hml   # ou prd

# 1. Cria primeiro os repositorios ECR (a imagem ainda nao existe)
terraform init
terraform apply -target=module.stack.module.ecr_lambda

# 2. Build e push da imagem da Lambda (repositorio service-track-lambda)
#    Dockerfile: https://github.com/Claudio712005/service-track-lambda
ECR_URL=$(terraform output -raw lambda_ecr_repository_url)
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "${ECR_URL%/*}"
docker build -t "$ECR_URL:latest" /caminho/service-track-lambda
docker push "$ECR_URL:latest"

# 3. Apply completo do ambiente
terraform apply
```

Nos applies seguintes, publique a nova imagem e rode `terraform apply` com
`-var="lambda_image_tag=<tag>"` (ou atualize o `terraform.tfvars`).

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
| `api_gateway_url` | URL pública do serviço de autenticação |
| `argocd_url` | URL do ArgoCD (se exposto) |
| `argocd_admin_password_cmd` | Comando para obter a senha inicial do admin |

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
