# RFC – 003: Infraestrutura como Código com Terraform

## Data
08/07/2026

Origem: decidida na Fase 2 em `service-track-api` como API-RFC-016, transferida para este
repositório na Fase 3 junto com a propriedade da infraestrutura (`API-ADR-020`,
`GLOBAL-RFC-006`). Conteúdo preservado; apenas a numeração e as referências foram
ajustadas ao esquema deste repositório.

---

## Status
- Encerrada – Aprovada

---

## Resumo

Proposta de provisionamento de toda a infraestrutura AWS (VPC, EKS, ECR, RDS) e da fundação de
GitOps (ArgoCD, metrics-server) com Terraform, state remoto em S3 e execução por pipeline.

---

## Problema

- O challenge exige Terraform para cluster e banco, com documentação de recursos.
- Conta AWS Academy é volátil (credenciais expiram em horas; conta pode ser recriada): sem IaC,
  cada sessão de lab exigiria reconstrução manual pelo console — lenta e sujeita a erro.
- Sem state remoto, execuções da pipeline e da máquina local divergiriam.

---

## Proposta Técnica

- **Terraform >= 1.10**, backend S3 com `use_lockfile` (lock sem DynamoDB).
- **Módulo único** em `infra/terraform/` com arquivos por domínio: `vpc.tf`, `eks.tf`, `ecr.tf`,
  `rds.tf`, `argocd.tf`, `variables.tf`, `outputs.tf`.
- **Rede:** VPC /16, 2 AZs (`us-east-1a/b`), subnets públicas (ELB) e privadas (nós/RDS),
  NAT único (custo de lab).
- **EKS:** 1.30, node group `t3.medium` 1–3 nós, `LabRole` (restrição Academy: roles não podem
  ser criadas).
- **RDS:** PostgreSQL 16 privado, senha master `random_password` exposta como output sensível.
- **ArgoCD + metrics-server** por `helm_release` com providers `helm`/`kubernetes` autenticados
  via `aws_eks_cluster_auth` — um `apply` entrega infraestrutura e motor de deploy.
- **Execução:** workflow `infra.yml` (dispatch: plan/apply/destroy) com credenciais em GitHub
  Secrets; localmente via `scripts/tf.sh` (perfil `aws-student`).

---

## Alternativas Consideradas

### Opção 1: CloudFormation/CDK
- Prós: integração nativa, state gerenciado pela AWS.
- Contras: lock-in; challenge pede Terraform; menos portável.

### Opção 2: eksctl + AWS CLI em shell scripts
- Prós: setup rápido do cluster.
- Contras: sem plan/diff, sem grafo de dependências, cobertura parcial (VPC/RDS/ECR à parte).

### Opção 3: Console manual
- Contras: irreprodutível, inauditável, incompatível com conta volátil. Descartada.

---

## Pontos em Aberto

- Módulos oficiais (terraform-aws-modules) para VPC/EKS — hoje recursos diretos, mais didáticos.
- NAT por AZ e RDS multi-AZ para produção real (custo dobra; fora do lab).

---

## Impactos

### Positivos
- Reconstrução completa do ambiente em ~20 min (`apply`) após reset do lab.
- Diff revisável (plan) antes de qualquer mudança de infraestrutura.

### Negativos
- Primeira criação pode requerer `apply` duplo (providers k8s/helm dependem do endpoint do EKS).
- Estado do banco não sobrevive ao `destroy` (skip_final_snapshot, decisão de lab).

---

## Próximos Passos

- Aprovado e implementado — ver [ADR-020](../adr/ADR-020-terraform-iac.md).
