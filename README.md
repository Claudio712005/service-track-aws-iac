# service-track-aws-iac

Plataforma AWS compartilhada do ServiceTrack: rede, cluster EKS com ArgoCD, a Lambda de
autenticação, o API Gateway público que a expõe e o NLB interno pelo qual a borda alcança o BFF.

> **As três flags da plataforma estão `true` por padrão** (`habilitar_autenticacao`,
> `habilitar_borda`, `habilitar_entrada_do_bff`) desde o `IAC-ADR-036`. Um `apply` entrega
> rede, EKS, ArgoCD, a descoberta dos microsserviços, a **Lambda de autenticação**, o
> **API Gateway público** e o **NLB interno** até o BFF.
>
> Elas andam juntas por dependência real, validada no `plan`: a borda exige a autenticação,
> e a autenticação exige a entrada do BFF, porque a Lambda alcança a verificação de
> credencial pelo NLB.
>
> **Pré-requisito da autenticação é o `service-track-usuarios-veiculos`, não o banco**: a
> Lambda não tem datasource e só pergunta `POST /credenciais/verificacao`.

**Este repositório cita microsserviço em um arquivo só.** Não há manifesto de aplicação,
repositório de imagem de aplicação, rota de negócio nem bloco `module` por serviço aqui. Cada
microsserviço carrega no próprio repositório os manifestos (`k8s/`) e a infraestrutura AWS de
que precisa (`infra/terraform/`), e entra no cluster sem nenhuma edição deste lado — ver
[kubernetes/README.md](kubernetes/README.md) e `IAC-ADR-026`.

A exceção é `apis/service-track-api-int/servicos-<ENV>.yaml`: a lista de quem fica atrás da API
privada, como dado, para que o módulo continue genérico (`IAC-ADR-033`).

A **segunda** exceção é [`compose/`](compose/README.md), que sobe a plataforma inteira na máquina
para exercitar a saga, a composição do BFF e o trace ponta a ponta sem precisar de `hml`. Ele
nomeia os cinco serviços porque descreve a composição deles, e a fronteira está escrita no
`IAC-ADR-037`: nada de Terraform, manifesto ou esteira por serviço.

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
  service-track-api-int/           Lista dos servicos atras da API privada (IAC-ADR-033)
    servicos-{HML,PRD}.yaml        nome, nodePort e caminho de health de cada servico

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
    entrada-do-bff/    NLB interno + VPC Link, para a borda publica alcancar o BFF
    stack/             Composicao dos modulos acima
  environments/
    hml/ prd/          Root modules finos, state key servicetrack/<env>

kubernetes/
  argocd/              AppProject, template de Application, bootstrap local
  kind/                Cluster local

compose/               Compose que sobe a plataforma inteira na maquina (IAC-ADR-037)
  docker-compose.yml   Os cinco servicos, os bancos, Redis, broker e Grafana
  observabilidade/     Prometheus, Tempo, Loki e o painel da plataforma

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
  metrics-server habilita o HPA dos microsserviços. A UI do ArgoCD atrás de LoadBalancer é
  **escolha de cada execução** da esteira, no campo `expor_argocd`: `padrao` usa o padrão do
  ambiente (`hml` sem, `prd` com), `sim` cria o LoadBalancer e `nao` remove. Ver `IAC-ADR-030`.

  Escolher `sim` em `hml` torna `scripts/aws-lb-cleanup.sh` obrigatório antes de destruir a
  rede: LoadBalancer criado pelo Kubernetes deixa ELB e ENI órfãos que travam a remoção da VPC.

  O acesso é `https://`, com **certificado autoassinado** gerado pelo próprio ArgoCD
  (`IAC-ADR-031`): o navegador avisa, e a CLI precisa de `argocd login <lb> --insecure`.
  Certificado válido exigiria nome de DNS e ACM, o que HML não tem.
- **Descoberta de microsserviços** — no fim de todo `apply`,
  `scripts/argocd-bootstrap-apply.sh` aplica o `AppProject` e gera uma `Application` para
  cada repositório do owner que tenha `k8s/argocd/<ambiente>.yaml` na `main`.
  A listagem usa a API do GitHub **autenticada** por `OPS_TOKEN` (ou `GITHUB_TOKEN`): sem
  token o limite é de 60 chamadas por hora **por IP**, e o IP de um runner do Actions é
  compartilhado — estourava e derrubava o apply inteiro no fim. Sem token o script ainda
  tenta, avisando.
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


- **Entrada do BFF** (`modules/entrada-do-bff`, só com `habilitar_entrada_do_bff = true`) — NLB
  interno e VPC Link, para a borda pública rotear `/bff` até o NodePort 30083. **Não há API
  privada e nenhum microsserviço tem rota em gateway** (`IAC-ADR-035`); os serviços falam entre si
  pelo DNS do cluster.

## Exposição da API

Há **uma** API pública, e ela expõe duas coisas:

```
Internet -> API Gateway REST publico (stage hml|prd)        habilitar_borda
              |-- POST /autenticacao      -> Lambda de autenticacao
              '-- /bff e /bff/{proxy+}    -> VPC Link -> NLB interno -> NodePort 30083 -> BFF
                                              habilitar_entrada_do_bff
```

Na borda pública o gateway aplica API key por consumidor (`x-api-key`), throttling, quota,
validação de request por JSON Schema, CORS e WAF. Rota fora do contrato responde `403`.

**Nenhum microsserviço é alcançável por gateway, exceto o BFF** (`IAC-ADR-035`). Não existe API
privada: ela foi removida junto com as rotas por serviço e o endpoint de interface do
`execute-api`. O NLB é `internal`, tem um alvo só — o BFF — e o NodePort 30083 só aceita tráfego
do security group do NLB.

Os serviços falam entre si pelo **DNS do cluster**, e o BFF os alcança pelo mesmo caminho. Fora
disso, um microsserviço é alcançado por outro pod ou por `kubectl port-forward`, que é você usando
a própria credencial e não uma porta aberta na internet.

`habilitar_borda = false` tira a entrada pública inteira, e com ela o login. Não é o padrão desde o `IAC-ADR-036`.

**O par porta/NodePort sobrou só para o BFF**, em 30083, entre
`apis/service-track-api-int/servicos-<ENV>.yaml` e o `Service type=NodePort` do repositório do
BFF. **As duas metades vivem em repositórios diferentes e nada valida o par** — porta divergente
aparece como alvo `unhealthy` no target group, não como erro de apply.

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
habilitar_borda        = true   # API Gateway publico a partir do contrato EXT
habilitar_entrada_do_bff = true  # NLB interno + VPC Link, para a borda alcancar o BFF
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
bash scripts/tf-init.sh stack hml
cd iac/environments/hml
terraform apply -target=module.stack.module.ecr_lambda
bash ../../../scripts/lambda-bootstrap-image.sh "$(terraform output -raw lambda_ecr_repository_url)" bootstrap
terraform apply
```

O `init` vai pelo `scripts/tf-init.sh` porque o backend é parcial: o nome do bucket de state
sai da conta em que você está logado, e não existe conta escrita no código. Ver `IAC-ADR-029`.

## Diferenças entre ambientes

| | hml | prd |
|---|---|---|
| Nodes EKS | `t3.medium` ×1 | `t3.medium` ×2 |
| Autenticação e borda | desligadas | desligadas |
| Memória da Lambda | 512 MB | 1024 MB |
| LoadBalancer do ArgoCD (padrão, alterável por execução) | não (port-forward) | sim |
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
| `aws-lb-cleanup.sh` | antes de todo `destroy` do stack — remove ELB/ENI órfãos que travam a VPC. Preserva o que tem `ManagedBy=terraform`: o NLB da entrada do BFF é destruído pelo `terraform destroy`, na ordem certa |
| `argocd-bootstrap-apply.sh` | chamado pelo apply; reexecutável à mão para registrar um microsserviço novo sem Terraform. Exporte `OPS_TOKEN` para não depender do limite anônimo da API do GitHub |
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
