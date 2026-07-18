# service-track-aws-iac

Infraestrutura como código (Terraform) para provisionar o ambiente AWS da aplicação
ServiceTrack: rede, cluster Kubernetes gerenciado, banco de dados e GitOps.

O provisionamento entrega uma VPC completa, um cluster EKS, um PostgreSQL no RDS,
um repositório ECR para as imagens da aplicação e o ArgoCD instalado no cluster para
entrega contínua.

## Arquitetura

O código Terraform cria e conecta os seguintes recursos:

- **VPC** (`vpc.tf`) — CIDR `10.0.0.0/16` em duas zonas de disponibilidade, com
  subnets públicas e privadas, Internet Gateway, um NAT Gateway e as tabelas de
  rota correspondentes. As subnets já vêm marcadas com as tags exigidas pelo EKS
  para descoberta de load balancers.
- **EKS** (`eks.tf`) — cluster gerenciado com endpoint público e um node group nas
  subnets privadas. Usa a role `LabRole` da conta (ambiente educacional AWS).
- **RDS** (`rds.tf`) — instância PostgreSQL privada, com storage criptografado e
  senha gerada aleatoriamente. O security group libera a porta 5432 apenas para o
  security group do cluster EKS.
- **ECR** (`ecr.tf`) — repositório `service-track-app` com scan de imagem no push.
- **ArgoCD e metrics-server** (`argocd.tf`) — instalados via Helm. O ArgoCD pode
  ser exposto por LoadBalancer público ou ficar interno (acesso por port-forward),
  controlado pela variável `argocd_expose_lb`. O metrics-server habilita o HPA.

O estado do Terraform é mantido em um bucket S3 (`versions.tf`), com lock via
`use_lockfile`.

## Pré-requisitos

- Terraform >= 1.10.0
- AWS CLI configurado com credenciais válidas
- `kubectl` e `helm` para operar o cluster após o provisionamento
- Bucket S3 do backend já existente (ver `versions.tf`)

## Uso

O código Terraform fica no diretório `api/`.

```bash
cd api

# copie e ajuste as variáveis conforme necessário
cp terraform.tfvars.example terraform.tfvars

terraform init
terraform plan
terraform apply
```

Depois do `apply`, configure o acesso ao cluster com o comando exposto pelo output
`configure_kubectl`:

```bash
aws eks update-kubeconfig --name servicetrack-dev --region us-east-1
```

### Outputs principais

| Output | Descrição |
|---|---|
| `cluster_name`, `cluster_endpoint` | Identificação e endpoint do EKS |
| `configure_kubectl` | Comando pronto para configurar o kubeconfig |
| `ecr_repository_url` | URL do repositório ECR |
| `rds_endpoint`, `rds_jdbc_url` | Endereço e URL JDBC do PostgreSQL |
| `db_username`, `db_password` | Credenciais do banco (senha marcada como sensível) |
| `argocd_url` | URL do ArgoCD (vazio se não exposto ou LB ainda provisionando) |
| `argocd_admin_password_cmd` | Comando para obter a senha inicial do admin |

## Variáveis

Todas as variáveis têm valores padrão em `variables.tf`. As mais relevantes:

| Variável | Padrão | Descrição |
|---|---|---|
| `aws_region` | `us-east-1` | Região dos recursos |
| `project` / `environment` | `servicetrack` / `dev` | Prefixo de nomes e tags |
| `cluster_name` / `cluster_version` | `servicetrack-dev` / `1.30` | EKS |
| `node_instance_types` | `["t3.medium"]` | Tipo dos nós |
| `node_desired_size` / `min` / `max` | `2` / `1` / `3` | Escala do node group |
| `db_instance_class` | `db.t3.micro` | Classe do RDS |
| `db_engine_version` | `16.9` | Versão do PostgreSQL |
| `argocd_expose_lb` | `true` | Expor ArgoCD via LoadBalancer público |

## Scripts

O diretório `scripts/` contém utilitários de operação:

- **`tf.sh`** — wrapper do Terraform que roda a limpeza de load balancers antes de
  um `destroy`.
- **`aws-lb-cleanup.sh`** — remove Services do tipo LoadBalancer e ELBs/ENIs órfãos
  antes de destruir a VPC, evitando que o `destroy` fique preso.
- **`aws-student-login.sh`** — grava credenciais temporárias no profile
  `aws-student`.
- **`bootstrap-prod.sh`** — cria namespace, secrets, roles no banco, o LoadBalancer
  da API e registra a Application no ArgoCD.
- **`db-seed.sh`** — aplica o seed inicial do banco via Job no cluster.
- **`demo-hpa.sh`** — gera carga na API para demonstrar o autoscaling horizontal.

Observação: `bootstrap-prod.sh`, `db-seed.sh` e `tf.sh` assumem um layout de
monorepo (`infra/terraform`, `infra/k8s`, `software/service-track-api`). Neste
repositório o Terraform está em `api/`; ajuste os caminhos ou a estrutura conforme
o seu ambiente antes de usá-los.

## Destruição

```bash
cd api
terraform destroy
```

Se o cluster tiver LoadBalancers ativos, rode `scripts/aws-lb-cleanup.sh` antes
para liberar os ELBs e ENIs e evitar que o `destroy` falhe ao remover a VPC.

  