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
  modules/
    network/       VPC, subnets publicas/privadas, IGW, NAT, rotas
    eks/           Cluster EKS + node group
    addons/        ArgoCD e metrics-server (Helm)
    app-secrets/   Bootstrap dos secrets e configmaps a partir do SSM
    ecr/           Repositorio de imagem (reutilizavel)
    lambda/        Lambda de autenticacao (imagem de container) + SG + logs
    lambda-authorizer/ Authorizer de JWT na borda (Go, provided.al2023) + testes
    vpc-link/      NLB interno + VPC Link (API Gateway -> EKS)
    api-gateway/   REST API a partir do openApi.yaml, usage plans, API keys,
                   CORS
    datadog-agent/ Node agent e cluster agent via Helm (hml e prd)
    observability/ Monitores e dashboard do Datadog
    stack/         Composicao que liga todos os modulos acima
  environments/
    hml/           Homologacao (node t3.small) - state key servicetrack/hml
    prd/           Producao   (node t3.medium) - state key servicetrack/prd

docs/
  adr/             Decisoes arquiteturais (ADR-001 a ADR-025)
  rfc/             RFC-001 a RFC-008
  diagramas/       Topologia de rede e diagrama de deployment (Mermaid)
  api-gateway/     Guia tecnico e operacional do gateway

.github/workflows/
  credenciais-aws.yml  Replica as credenciais da AWS nos quatro repositorios
  subir-ambiente.yml   Orquestra rede, banco, stack, Lambda e aplicacao na ordem
  destruir-ambiente.yml Ordem inversa, com escopo so-o-stack ou tudo
  network.yml          Aplica a rede do ambiente (manual) - primeira fase
  terraform.yml        plan / apply / destroy por ambiente (manual)
  bootstrap-state.yml  Cria o bucket S3 do state (manual, uma vez por conta)
  unlock-state.yml     Remove lock orfao de um state
  contract.yml         Valida contrato + authorizer + fmt/validate (push e PR)
  deploy-image.yml     Recebe image-published da API e reescreve a tag do overlay
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
recebe o endpoint `execute-api` do ambiente. **Essa URL muda a cada recriação**, nos dois
ambientes — links de e-mail gerados antes de um `destroy` deixam de resolver.

A validação do JWT fica no backend por padrão, e opcionalmente também na borda
(`enable_jwt_authorizer`).

> **Domínio próprio foi removido** (`ADR-008`, revogada). Não é requisito do Tech Challenge e
> o passo de delegação no Registro.br não tem API, o que o tornava trabalho manual recorrente
> numa conta que é recriada.

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
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | GitHub → **este repo** → **Repository secrets** | a cada laboratório | AWS Academy → AWS Details → AWS CLI. Depois rode a esteira **Credenciais AWS**, que replica nos quatro repositórios |
| `IAC_REPO_TOKEN` | GitHub → **repo da API** → Secrets | uma vez | PAT fino / GitHub App, `contents: write` só neste repo |
| `UNSPLASH_ACCESS_KEY` | GitHub → **este repo** → Environments `hml` e `prd` | uma vez | painel do Unsplash |
| `RESEND_API_KEY` | GitHub → **este repo** → Environments `hml` e `prd` | uma vez | painel do Resend |
| `DD_API_KEY` | GitHub → **este repo** → Environments `hml` e `prd` | uma vez | Datadog → Organization Settings → API Keys |
| `DD_APP_KEY` | GitHub → **este repo** → Environments `hml` e `prd` | uma vez | Datadog → Organization Settings → Application Keys |
| `OPS_TOKEN` | GitHub → **este repo** → Repository secrets | uma vez | PAT fine-grained nos quatro repositorios, com `Actions: write`, `Secrets: write` e `Environments: read`. Usado pelas esteiras de orquestracao |
| `DD_NOTIFICACAO` | GitHub → **este repo** → Environments `hml` e `prd` | uma vez | Destino do alerta no formato do Datadog: `@voce@dominio.com` para e-mail, `@slack-canal` para Slack |

**Segredo que pode ser gerado é gerado no apply** ([ADR-018](docs/adr/ADR-018-segredos-gerados-no-apply.md)).
Só permanecem como secret do GitHub os que vêm de terceiro.

| Segredo | Origem |
|---|---|
| Par RS256 do JWT | `tls_private_key` no apply, alimentando Lambda e aplicação de uma vez |
| Segredo do header do gateway | gerado no apply |
| Senhas de `app_user`, `flyway_user`, `readonly_user` | geradas em `service-track-db-infra`, lidas do SSM |
| Chaves do Unsplash e do Resend | secrets do GitHub, entregues por `TF_VAR_*` |

Nada disso precisa ser colado à mão a cada recriação. O bootstrap **compõe** os secrets do
Kubernetes lendo do SSM, e falha com mensagem explícita se o repositório de banco não tiver
sido aplicado antes.

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

**Não precisa gerar nada.** O par é criado pelo Terraform a cada apply e entregue aos dois
consumidores na mesma execução — a Lambda por variável de ambiente, a aplicação por secret do
Kubernetes. Isso elimina a chance de os dois lados receberem pares diferentes, que produzia
token emitido com sucesso e recusado pelo backend.

Recriar o ambiente troca o par e invalida os tokens em circulação. É o comportamento esperado
num ambiente descartável.

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

## Observabilidade

Datadog em `hml` e `prd`, provisionado por Terraform. O agente entra no cluster por Helm e os
dashboards e monitores são recursos Terraform — nada é criado pela interface do Datadog, para
que sobrevivam à recriação do ambiente.

### Duas chaves, dois papéis

| Secret | Para quê | Sem ela |
|---|---|---|
| `DD_API_KEY` | ingestão de métricas, traces e logs pelo agente | a observabilidade fica **desligada** no ambiente inteiro |
| `DD_APP_KEY` | criar dashboards e monitores pela API do Datadog | o agente sobe e coleta, mas nenhum alerta ou dashboard é criado |
| `DD_NOTIFICACAO` | destino das notificações dos monitores | os monitores disparam, mas só aparecem no painel de Monitors do Datadog — ninguém é avisado |

Ambas vão em **Settings → Secrets and variables → Actions → Secrets**, nos environments `hml`
e `prd`. `DD_API_KEY` vazia desliga a observabilidade sem quebrar o apply — é o que permite
subir um ambiente sem Datadog quando o orçamento aperta.

### O que sobe no cluster

| Componente | Forma | Por quê |
|---|---|---|
| Node agent | DaemonSet | um por node; coleta métricas, logs e recebe OTLP na porta do host |
| Cluster agent | Deployment | metadados de cluster, `kubernetes_state`, evita que cada node consulte a API do Kubernetes |

A aplicação envia OTLP para o **agente do próprio node**, via `status.hostIP`. Não há serviço
intermediário: manter a coleta local ao node preserva a correlação entre o trace e o host que
o gerou.

### Diferenças entre ambientes

| | hml | prd |
|---|---|---|
| Réplicas do cluster agent | 1 | **2** |
| Espalhadas por AZ | não | **sim** |
| Recursos do node agent | 100m / 256Mi | 200m / 512Mi |
| Latência p95 que alerta | 3 s | 1,5 s |
| Erros 5xx em 5 min | 20 | 10 |
| Falhas de OS em 15 min | 10 | 5 |
| Mínimo de pods prontos | 1 | 2 |
| Saturação de CPU | 90% | 80% |

Sobre **duas AZ**: o node agent é DaemonSet, então já cobre todas as zonas onde existem nodes
— não há decisão a tomar. A pergunta só se aplica ao **cluster agent**, que é um Deployment.
Em PRD são duas réplicas com anti-afinidade por `topology.kubernetes.io/zone`. Em HML o node
group tem **um node**, então duas réplicas não teriam onde espalhar e a segunda ficaria
pendente — por isso uma só.

Vale lembrar que o Datadog é SaaS: perder o cluster agent não perde dado de aplicação, porque
os node agents seguem enviando. O que para é a coleta de metadados do cluster. A alta
disponibilidade dele é conforto operacional, não durabilidade.

### Monitores criados

| Monitor | Dispara quando |
|---|---|
| Latência alta na API | p95 acima do limite por 10 min |
| Taxa de erro 5xx | respostas 5xx acima do limite em 5 min |
| **Falha no processamento de ordens de serviço** | erros no domínio de OS em 15 min |
| Pods indisponíveis | réplicas prontas abaixo do mínimo, ou sem dado por 20 min |
| Saturação de CPU nos nodes | uso acima do limite por 10 min |
| Falhas nas integrações externas | erros de rest-client em 15 min |
| Banco próximo do teto de conexões | uso acima do limite do orçamento declarado no repositório de banco |

O dashboard traz volume diário de OS, tempo médio por status, latência por rota, erros de
integração, CPU e memória dos pods, réplicas do HPA, conexões do banco e uptime.

> As métricas de negócio (`servicetrack.ordem_servico.*`) dependem de instrumentação na
> aplicação. Os widgets existem e ficam vazios até ela ser adicionada.

---

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
| **Credenciais AWS** | manual — a cada sessao nova do laboratorio, replica as tres secrets nos quatro repositorios |
| **Subir ambiente** | manual — orquestra rede, banco, stack, Lambda e aplicacao na ordem |
| **Destruir ambiente** | manual — a ordem inversa, com escopo `so-o-stack` ou `tudo` |
| **Bootstrap do state** | manual — uma vez por conta AWS, antes de tudo |

---

## Ordem de subida de um ambiente

Os ambientes são efêmeros e esta ordem vale para **toda** recriação. Ela existe porque o
banco precisa da VPC para nascer, e este stack precisa do banco (`DB-ADR-003`).

| # | Repositório | Esteira | O quê |
|---|---|---|---|
| 0 | este | `scripts/bootstrap-tfstate.sh` | bucket S3 do state — **uma vez por conta AWS** |
| 1 | este | **Network** → `apply` | VPC e subnets |
| 2 | `service-track-db-infra` | **Terraform** → `apply` | RDS, parameter group, SSM |
| 3 | este | **Terraform** → `apply` | EKS, Lambda, gateway, ingress no SG do banco |
| 4 | — | hook `PreSync` do ArgoCD | extensões e roles do banco, automático |

### Fase 0 — o bucket de state

Todas as esteiras dos dois repositórios usam o mesmo backend S3. Sem ele, o `terraform init`
falha com `S3 bucket ... does not exist` antes de qualquer plano.

```bash
scripts/bootstrap-tfstate.sh
```

O script é idempotente: cria o bucket com versionamento, criptografia e bloqueio de acesso
público, ou apenas confirma que já existe.

O nome do bucket carrega o **ID da conta** e está fixado em 12 lugares entre este repositório e
o `service-track-db-infra`. Se a conta do laboratório for recriada com outro ID, o script
detecta e imprime o comando de substituição — rode-o antes de qualquer apply.

**Este bucket sobrevive ao `destroy` dos ambientes, de propósito.** Só desaparece se a conta
for resetada.

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

HML é o ambiente enxuto: **sem LoadBalancer do ArgoCD e sem
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

Mesma sequência de HML, trocando `env` para `prd`:

1. **Network** → `apply` · `env: prd`
2. `service-track-db-infra` → **Terraform** → `apply` · `env: prd`
3. **Terraform** → `apply` · `env: prd` · `lambda_image_tag: bootstrap` no primeiro apply
4. `service-track-lambda` → **CD** · `env: prd`
5. `service-track-api` → **CD - App** · `env: prd`

PRD difere de HML em: `t3.medium` no node group, HPA de 2 a 4, LoadBalancer do ArgoCD ligado,
WAF habilitado, RDS Multi-AZ com backup de 7 dias e limiares de alerta mais apertados.

A API é servida pelo endpoint `execute-api` nos dois ambientes.

### Destruir um ambiente

**Actions → Terraform → Run workflow** com `action: destroy` e o `env` desejado.
A esteira limpa antes os LoadBalancers órfãos criados pelo Kubernetes.

O bucket de state **não** é destruído: ele guarda os states de todos os ambientes e é
pré-requisito da próxima recriação. Ver a esteira **Bootstrap do state**.

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
| Nodes EKS          | `t3.small` ×1 | `t3.medium` 1..2 |
| Node group (min/desired/max) | 1 / 1 / 2 | 2 / 2 / 4 |
| RDS                | `db.t3.micro` | `db.t3.medium` |
| Storage RDS        | 20 GB         | 50 GB          |
| Memória da Lambda  | 512 MB        | 1024 MB        |
| VPC CIDR           | `10.10.0.0/16`| `10.20.0.0/16` |
| State (key S3)     | `servicetrack/hml` | `servicetrack/prd` |
| LoadBalancer do ArgoCD | não (port-forward) | sim |
| Métricas detalhadas do API Gateway | não | não |
| Retenção de log do gateway | 3 dias | 14 dias |

**HML foi enxugado de propósito** para liberar orçamento para observabilidade
(Datadog). Os cortes, em ordem de impacto:

| Corte | Economia | Contrapartida |
|---|---|---|
| Métricas detalhadas do API Gateway desligadas | até ~US$ 100/mês | métricas agregadas por stage continuam, e são grátis |
| ArgoCD sem LoadBalancer | ~US$ 16/mês | acesso por `kubectl port-forward` |
| Sem domínio próprio | ~US$ 0,50/mês de hosted zone evitado | URL do `execute-api` muda a cada recriação |
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
| `app_backend_nlb_dns` | DNS do NLB interno que expõe a aplicação do EKS |
| `argocd_url` | URL do ArgoCD (se exposto) |
| `argocd_admin_password_cmd` | Comando para obter a senha inicial do admin |

A URL e a API key **mudam a cada recriação do ambiente** — leia-as dos outputs,
não as fixe em código de cliente:

```bash
terraform output api_gateway_url
terraform output -json api_key_values | jq -r .web
```


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

| Script | Quando |
|---|---|
| `bootstrap-tfstate.sh` | **antes de tudo**, uma vez por conta AWS — cria o bucket S3 do state |
| `aws-lb-cleanup.sh` | **antes de todo `destroy`** — remove ELB/ENI órfãos que travam a VPC |
| `gen-local-jwt-keys.sh` | ao preparar o ambiente local (kind) |
| `validate-openapi.sh` | antes de qualquer apply que altere o contrato |
| `contract-test.sh` | após o apply, valida a API publicada |

## Destruição

```bash
cd iac/environments/prd
terraform destroy
```

Se o cluster tiver LoadBalancers ativos (ArgoCD, apps), rode
`scripts/aws-lb-cleanup.sh` antes para liberar ELBs e ENIs órfãos e evitar que o
`destroy` falhe ao remover a VPC.
