# ADR – 020: Infraestrutura como Código com Terraform

## Data
08/07/2026

Origem: decidida na Fase 2 em `service-track-api` como API-ADR-016, transferida para este
repositório na Fase 3 junto com a propriedade da infraestrutura (`API-ADR-020`,
`GLOBAL-RFC-006`). Conteúdo preservado; apenas a numeração e as referências foram
ajustadas ao esquema deste repositório.

---

## Status

- Aceita

---

## Contexto

A Fase 2 exige IaC para provisionar o cluster Kubernetes e o banco de dados, com documentação de
recursos e forma de aplicação. O ambiente AWS Academy tem credenciais temporárias (session token
rotativo) e contas que podem ser resetadas — a infraestrutura precisa ser reproduzível do zero em
uma execução. Provisionamento manual pelo console não é auditável nem repetível.

---

## Decisão

Adotar **Terraform** (>= 1.10) como ferramenta única de IaC, em `infra/terraform/`:

- **State remoto no S3** (`servicetrack-tfstate-*`) com criptografia e lock nativo
  (`use_lockfile`), permitindo execução local e via pipeline sem conflito.
- **Recursos provisionados:**
  - `vpc.tf` — VPC 10.0.0.0/16, subnets públicas/privadas em 2 AZs, IGW, NAT Gateway único,
    tabelas de rota (tags de descoberta de subnets para ELB do EKS).
  - `eks.tf` — cluster EKS 1.30 + node group gerenciado (usa `data aws_iam_role LabRole`,
    restrição do Learner Lab — não é permitido criar roles).
  - `ecr.tf` — repositório `service-track-app` com scan on push.
  - `rds.tf` — PostgreSQL 16 (db.t3.micro, gp3, criptografado, privado), senha master via
    `random_password`, security group liberando 5432 apenas para o SG do cluster.
  - `argocd.tf` — **ArgoCD e metrics-server via `helm_release`** (providers `helm`/`kubernetes`
    autenticados no próprio cluster criado no state), com versões de chart fixadas por variável.
- **Outputs** consumidos pelos scripts operacionais (`rds_jdbc_url`, `db_password`,
  `ecr_repository_url`, `cluster_name`, `argocd_url`).
- **Execução via pipeline** `infra.yml` (workflow_dispatch: plan/apply/destroy) ou local pelo
  wrapper `scripts/tf.sh`.

---

## Consequências

### Positivas
- Ambiente inteiro reproduzível do zero (`apply`) e descartável (`destroy`) — essencial no lab.
- State compartilhado e travado no S3: pipeline e máquina local cooperam sem corromper estado.
- ArgoCD entra como parte da fundação: um `apply` entrega cluster **e** motor de GitOps.
- Outputs eliminam copy/paste de endpoints e senhas entre etapas.

### Negativas
- Providers `helm`/`kubernetes` autenticando num cluster criado no mesmo state podem exigir um
  segundo `apply` na criação inicial (corrida de disponibilidade do endpoint).
- `LabRole` única para cluster e nós fere o princípio de menor privilégio (aceito por restrição
  do Learner Lab).
- Recursos criados pelo cluster em runtime (ELBs de Services) ficam fora do state — o destroy
  exige remover os Services LoadBalancer antes (documentado em `infra/GITOPS_AWS.md`).

---

## Alternativas Consideradas

### Opção 1: CloudFormation / CDK
- Prós: nativo AWS, sem state externo.
- Contras: lock-in, verbosidade (CFN), curva do CDK; Terraform é o padrão pedido no challenge.

### Opção 2: eksctl + scripts
- Prós: rápido para subir EKS.
- Contras: cobre só o cluster; VPC/RDS/ECR ficariam em ferramentas separadas, sem grafo único de
  dependências nem plan/diff.

---

## Referências

- [RFC-003 – IaC com Terraform](../rfc/RFC-003-terraform-iac.md)
- Código: `infra/terraform/` · Pipeline: `.github/workflows/infra.yml`
- ADR-019 (EKS), ADR-021 (ArgoCD), ADR-022 (bootstrap e scripts)
