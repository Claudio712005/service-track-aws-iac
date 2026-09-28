# service-track-aws-iac

Plataforma AWS compartilhada do ServiceTrack: rede, cluster EKS com ArgoCD e, quando
habilitadas, a Lambda de autenticação e o API Gateway que a expõe.

> **Autenticação e borda estão desligadas** (`habilitar_autenticacao` e `habilitar_borda`,
> ambas `false`). Um `apply` hoje entrega rede, EKS, ArgoCD e os microsserviços
> descobertos — nada mais. Motivo: cada microsserviço terá o próprio banco e a modelagem de
> dados da Fase 4 ainda não fechou; sem essa decisão, a Lambda de autenticação (que lê o RDS
> do monólito) e o gateway (cuja única rota é o login) ficam fora. Ver `IAC-ADR-027`.

**Este repositório não conhece nenhum microsserviço.** Não há nome de serviço, manifesto de
aplicação, repositório de imagem de aplicação nem rota de negócio aqui. Cada microsserviço
carrega no próprio repositório os manifestos (`k8s/`) e a infraestrutura AWS de que precisa
(`infra/terraform/`), e entra no cluster sem nenhuma edição deste lado — ver
[kubernetes/README.md](kubernetes/README.md) e `IAC-ADR-026`.

> **O banco de dados não vive aqui.** O RDS está em
> [service-track-db-infra](https://github.com/Claudio712005/service-track-db-infra)
> (`DB-ADR-003`), e com a autenticação desligada este repositório não lê mais nada dele.

## Estrutura

```
apis/
  service-track-api-ext/           Contrato de borda do API Gateway
    openApi.yaml                   Definicao do gateway (importada pelo Terraform)
    api-configuration/
      cors/config-{HML,PRD}.yaml       CORS por ambiente
      usage-plan/config-{HML,PRD}.yaml Throttling, quota, consumidores, logs e WAF

iac/
  network/
    hml/ prd/          VPC e subnets - state proprio, primeira fase de cada ambiente
  modules/
    network/           VPC, subnets publicas/privadas, IGW, NAT, rotas
    eks/               Cluster EKS + node group
    addons/            ArgoCD e metrics-server (Helm)
    ecr/               Repositorio de imagem (usado pela Lambda)
    lambda/            Lambda de autenticacao (imagem de container) + SG + logs
    lambda-authorizer/ Authorizer de JWT na borda (Go) + testes, opcional
    api-gateway/       REST API a partir do openApi.yaml, usage plans, API keys, CORS, WAF
    stack/             Composicao dos modulos acima
  environments/
    hml/ prd/          Root modules finos, state key servicetrack/<env>

kubernetes/
  argocd/              AppProject, template de Application, bootstrap local
  kind/                Cluster local

scripts/               Operacao e diagnostico (ver "Scripts")
docs/                  ADRs, RFCs, guia do gateway e diagramas

.github/workflows/
  subir-ambiente.yml     Rede e stack de um ambiente, na ordem
  destruir-ambiente.yml  Stack, e opcionalmente rede, na ordem inversa
  terraform.yml          plan / apply / destroy de uma camada (manual ou chamado pelas duas acima)
  credenciais-aws.yml    Replica as credenciais AWS na plataforma e nos microsservicos
  bootstrap-state.yml    Cria o bucket S3 do state (uma vez por conta)
  unlock-state.yml       Remove lock orfao de um state
  contract.yml           Valida contrato, authorizer e fmt/validate (push e PR)
```

## O que o stack provisiona

- **EKS** (`modules/eks`) — cluster com endpoint público e node group nas subnets privadas.
  Usa a role `LabRole` da conta (AWS Academy).
- **Addons** (`modules/addons`) — ArgoCD e metrics-server via Helm, nos dois ambientes. O
  metrics-server habilita o HPA dos microsserviços. Em `prd` a UI do ArgoCD fica atrás de um
  LoadBalancer; em `hml`, só por port-forward.
- **Descoberta de microsserviços** — no fim de todo `apply`,
  `scripts/argocd-bootstrap-apply.sh` aplica o `AppProject` e gera uma `Application` para
  cada repositório do owner que tenha `k8s/argocd/<ambiente>.yaml` na `main`.
- **Lambda de autenticação** (`modules/lambda`, só com `habilitar_autenticacao = true`) —
  imagem de container nas subnets privadas,
  com a regra de entrada na porta 5432 do security group do banco. Assina o JWT com o par
  RS256 gerado no apply.
- **Chave pública do JWT** — publicada em `/servicetrack/<env>/jwt-public` no SSM, para os
  microsserviços validarem o token sem depender deste repositório.
- **API Gateway** (`modules/api-gateway`, só com `habilitar_borda = true`) — REST API
  construída a partir do `openApi.yaml`.
  Hoje expõe só `POST /autenticacao`, roteado para a Lambda. A URL base vai para
  `/servicetrack/<env>/api/base-url` no SSM.

## Exposição da API

```
Internet -> API Gateway REST (stage hml|prd)
              '-- POST /autenticacao -> Lambda de autenticacao
```

Na borda o gateway aplica API key por consumidor (`x-api-key`), throttling, quota, validação
de request por JSON Schema e CORS. Rota fora do contrato responde `403`.

**Os microsserviços não são expostos pelo gateway, nem por nada.** Não há VPC Link, NLB nem
NodePort. Um microsserviço é alcançado de dentro do cluster (outro pod, ou um BFF quando
existir) ou por `kubectl port-forward`, que é você usando a própria credencial e não uma
porta aberta na internet.

Com `habilitar_borda = false` — o padrão de hoje — nem o gateway existe.

Antes de qualquer `apply` que altere o contrato:

```bash
scripts/validate-openapi.sh
( cd iac/modules/lambda-authorizer/src && go test ./... )
```

As duas checagens rodam em push/PR (`contract.yml`), e `scripts/contract-test.sh` valida a API
publicada ao fim de cada apply do stack. Guia completo em
[docs/api-gateway/README.md](docs/api-gateway/README.md).

## Segredos

Nenhum material sensível é versionado (`IAC-ADR-013`).

| Segredo | Onde vive | Quando | Origem |
|---|---|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | este repo → Repository secrets | a cada laboratório | AWS Academy → AWS Details → AWS CLI. Depois rode **Credenciais AWS** |
| `OPS_TOKEN` | este repo → Repository secrets | uma vez | PAT fine-grained, usado só pela esteira **Credenciais AWS** |

O `OPS_TOKEN` precisa de acesso a **todos os repositórios** do owner (a lista de destino é
descoberta, não fixa), com as permissões:

| Permissão | Nível |
|---|---|
| Contents | Read |
| Secrets | Read and write |
| Environments | Read |
| Metadata | Read |

**O que é gerado no apply** (`IAC-ADR-018`): o par RS256 do JWT (`tls_private_key`). A chave
privada vai para a Lambda por variável de ambiente; a pública, para a Lambda e para o SSM.
Recriar o ambiente troca o par e invalida os tokens em circulação — comportamento esperado
num ambiente descartável.

> **Limitação aceita (`I-16`):** a chave privada fica gravada no state em S3, porque passa
> por variável da Lambda.

## Esteiras

| Esteira | Quando |
|---|---|
| **Bootstrap do state** | uma vez por conta AWS, antes de tudo |
| **Credenciais AWS** | a cada sessão nova do laboratório |
| **Subir ambiente** | rede → stack, chamando **Terraform** como workflow reutilizável |
| **Destruir ambiente** | stack, e com escopo `tudo` também a rede |
| **Terraform** | manual — `plan`, `apply` ou `destroy` de uma camada (`rede` ou `stack`) |
| **Contract** | automática, em push/PR que toca o contrato ou os módulos do gateway |
| **Unlock state** | lock órfão depois de uma execução interrompida |

Nenhuma esteira deste repositório dispara esteira de outro repositório. O banco, a Lambda e
cada microsserviço são operados pelas esteiras dos próprios repositórios.

### Credenciais AWS

Grava as três secrets, no nível do repositório e nos environments `hml` e `prd` quando
existirem, em:

- `service-track-aws-iac`, `service-track-db-infra`, `service-track-lambda` — plataforma;
- todo repositório do owner com `k8s/argocd/` ou `infra/terraform/` na branch padrão —
  microsserviços, descobertos a cada execução.

Microsserviço novo recebe credencial sem edição aqui.

## Ordem de subida de um ambiente

Os ambientes são efêmeros e esta ordem vale para **toda** recriação.

| # | Repositório | Esteira | O quê |
|---|---|---|---|
| 0 | este | **Bootstrap do state** | bucket S3 do state — uma vez por conta |
| 1 | este | **Terraform** → `apply` · `camada: rede` | VPC e subnets |
| 2 | `service-track-db-infra` | **Terraform** → `apply` | RDS — **só com `habilitar_autenticacao = true`** |
| 3 | este | **Subir ambiente** | rede (idempotente) → EKS, ArgoCD |
| 4 | cada microsserviço | a própria esteira | infra em `infra/terraform`, imagem no ECR próprio, deploy pelo ArgoCD |

Os passos 2, e depois a Lambda, só voltam quando `habilitar_autenticacao` for ligada.

O stack confere rede e banco antes de começar e falha apontando o que rodar antes.

**Destruir é a ordem inversa:** **Destruir ambiente** com `so-o-stack` → `destroy` do banco
no `service-track-db-infra` → **Destruir ambiente** com `tudo`. A destruição da rede recusa
seguir enquanto o banco existir.

A infraestrutura de cada microsserviço (ECR e o que mais houver) vive em state próprio e
**não** é destruída por este repositório.

### Antes de qualquer esteira

A conta é AWS Academy: as credenciais mudam a cada laboratório e as esteiras falham com
`ExpiredToken` se estiverem velhas. Atualize as três secrets deste repositório e rode
**Credenciais AWS**.

## Ligar autenticação e borda

```hcl
habilitar_autenticacao = true   # Lambda + ECR dela + par RS256 + leitura do RDS
habilitar_borda        = true   # API Gateway a partir do contrato EXT
```

`habilitar_borda` exige `habilitar_autenticacao`: a única rota publicada é o login, e sem ela
o gateway não teria nenhuma integração. O `plan` falha com essa mensagem se a combinação for
inválida.

Com a autenticação ligada, o banco do `service-track-db-infra` volta a ser pré-requisito do
`apply`, na ordem rede → banco → stack.

## Lambda: bootstrap da imagem

Imagens de Lambda só podem vir de ECR privado da própria conta, e o ECR nasce no mesmo apply.
O `apply` do stack resolve em três fases, automaticamente na esteira:

1. Cria o ECR da Lambda.
2. Publica o placeholder `:bootstrap` (base `public.ecr.aws/lambda/java:21`).
3. Apply completo: a função nasce de `:bootstrap`.

O código real é publicado pela esteira **CD** do
[service-track-lambda](https://github.com/Claudio712005/service-track-lambda). O módulo tem
`lifecycle { ignore_changes = [image_uri] }`: o Terraform gerencia a infraestrutura da função,
não o código. Até o CD rodar, `POST /autenticacao` responde erro.

Manualmente:

```bash
cd iac/environments/hml
terraform init
terraform apply -target=module.stack.module.ecr_lambda
bash ../../../scripts/lambda-bootstrap-image.sh "$(terraform output -raw lambda_ecr_repository_url)" bootstrap
terraform apply
```

## Diferenças entre ambientes

| | hml | prd |
|---|---|---|
| Nodes EKS | `t3.medium` ×1 | `t3.medium` ×2 |
| Autenticação e borda | desligadas | desligadas |
| Memória da Lambda | 512 MB | 1024 MB |
| LoadBalancer do ArgoCD | não (port-forward) | sim |
| State (key S3) | `servicetrack/hml` | `servicetrack/prd` |

Throttling, quota, retenção de log e WAF do gateway vêm de
`apis/service-track-api-ext/api-configuration/*/config-{HML,PRD}.yaml`.

Maiores custos: control plane do EKS (~US$ 73/mês por cluster) e NAT Gateway (~US$ 32/mês).
Destruir HML quando não estiver em uso é o corte mais eficaz.

## Outputs

| Output | Descrição |
|---|---|
| `configure_kubectl` | comando para configurar o kubeconfig |
| `lambda_ecr_repository_url` | ECR da Lambda |
| `lambda_function_name` | função de autenticação |
| `rds_endpoint` | banco lido pela Lambda (vem do SSM do db-infra) |
| `api_gateway_url` | URL base pública, já com o stage |
| `api_gateway_id` | ID do REST API |
| `api_consumers` | consumidores habilitados |
| `api_key_values` | consumidor → API key (sensível) |
| `jwt_public_key_parameter` | parâmetro SSM com a chave pública do JWT |
| `argocd_url` | URL do ArgoCD, quando exposto |
| `argocd_admin_password_cmd` | comando para ler a senha inicial do admin |

URL e API key **mudam a cada recriação**. Leia na hora de usar:

```bash
scripts/diagnostico/chave-de-api.sh hml
```

Acesso ao ArgoCD em `hml`:

```bash
aws eks update-kubeconfig --name servicetrack-hml --region us-east-1
kubectl -n argocd port-forward svc/argocd-server 8081:80
```

## Scripts

| Script | Quando |
|---|---|
| `bootstrap-tfstate.sh` | antes de tudo, uma vez por conta AWS |
| `aws-lb-cleanup.sh` | antes de todo `destroy` do stack — remove ELB/ENI órfãos que travam a VPC |
| `argocd-bootstrap-apply.sh` | chamado pelo apply; reexecutável à mão para registrar um microsserviço novo sem Terraform |
| `lambda-bootstrap-image.sh` | fase 2 do bootstrap da Lambda |
| `validate-openapi.sh` | antes de qualquer apply que altere o contrato |
| `contract-test.sh` | após o apply, valida a API publicada |
| `diagnostico/` | leitura do estado real de um ambiente — ver [scripts/diagnostico/README.md](scripts/diagnostico/README.md) |

## Pré-requisitos locais

- Terraform >= 1.10.0
- AWS CLI com credenciais válidas
- `kubectl`, `curl` e `python3` — usados pelo apply para registrar os microsserviços
- Docker — bootstrap da imagem da Lambda
- Go >= 1.23 — só com `enable_jwt_authorizer = true`

Índice das decisões: [docs/README.md](docs/README.md).
