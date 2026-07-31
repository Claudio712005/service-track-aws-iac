# RFC – 005: Bootstrap de Segredos/Config Dinâmica e Scripts Operacionais

## Data
08/07/2026

Origem: decidida na Fase 2 em `service-track-api` como API-RFC-018, transferida para este
repositório na Fase 3 junto com a propriedade da infraestrutura (`API-ADR-020`,
`GLOBAL-RFC-006`). Conteúdo preservado; apenas a numeração e as referências foram
ajustadas ao esquema deste repositório.

---

## Status
- Encerrada – Aprovada

---

## Resumo

Proposta de um processo de bootstrap imperativo e idempotente para tudo que o GitOps não pode
versionar (segredos, roles de banco, config que só existe em runtime), mais o conjunto de scripts
operacionais de apoio ao ambiente de lab.

---

## Problema

- Segredos (senhas de DB, chaves JWT RS256, API keys Resend/Unsplash) não podem ir ao Git, mas o
  Deployment depende deles (`envFrom`/volume).
- `DB_JDBC_URL` (output do Terraform) e `SERVICETRACK_API_BASE_URL` (hostname do ELB, que só
  existe depois que o próprio app sobe o Service) não são declaráveis em manifesto estático.
- External Secrets Operator exige IRSA — indisponível com a `LabRole` do AWS Academy.
- Credenciais do lab expiram em horas; operações repetitivas (login AWS, terraform, seed, carga
  de demo) precisam ser scriptadas para serem repetíveis.

---

## Proposta Técnica

1. **`scripts/bootstrap-prod.sh`** (acionado pelo workflow `bootstrap-prod.yml`), idempotente
   (`kubectl create --dry-run=client -o yaml | kubectl apply`):
   - lê outputs do Terraform (JDBC, senha master do RDS, cluster);
   - cria Secrets `service-track-jwt` e `service-track-secret` a partir de GitHub Secrets;
   - roda o Job `db-init` que provisiona `flyway_user` (DDL) e `app_user` (DML) no RDS;
   - aplica o Service LoadBalancer, espera o hostname e grava o ConfigMap
     `service-track-runtime` (JDBC + base-url pública para os magic links);
   - registra AppProject/Application no ArgoCD e publica resumo (URLs, login de demo do Argo).
2. **Contrato com o GitOps:** o Deployment versionado referencia
   `service-track-config` (Git) **+** `service-track-runtime`/`service-track-secret`
   (bootstrap); o AppProject lista esses recursos em `orphanedResources.ignore`.
3. **Scripts locais:** `aws-student-login.sh` (perfil com credenciais temporárias), `tf.sh`
   (wrapper Terraform), `db-seed.sh` (seed via Job), `demo-hpa.sh` (carga autenticada para a
   demo de escalabilidade).
4. **Ordem operacional documentada** (`infra/GITOPS_AWS.md`): Terraform apply → Bootstrap →
   CD/GitOps.

---

## Alternativas Consideradas

### Opção 1: External Secrets Operator + Secrets Manager
- Prós: cofre gerenciado, rotação, zero segredo na pipeline.
- Contras: IRSA bloqueado no Learner Lab. Evolução natural pós-lab.

### Opção 2: Sealed Secrets
- Prós: segredo cifrado no Git, fluxo 100% GitOps.
- Contras: não cobre valores dinâmicos de runtime; gestão da chave privada do controller.

### Opção 3: envsubst de manifests na pipeline de CD (modelo anterior)
- Prós: um passo só.
- Contras: mistura deploy com segredo, re-injeta tudo a cada deploy e conflita com o selfHeal
  do ArgoCD. Substituída.

---

## Pontos em Aberto

- Migração para ESO/Sealed Secrets quando houver IAM completo.
- `aws-student-login.sh` lê credenciais coladas no arquivo — mover para variáveis de
  ambiente/stdin para eliminar risco de commit de token (mesmo temporário).

---

## Impactos

### Positivos
- Zero segredo versionado; ambiente reconstruível em 3 passos (infra → bootstrap → CD).
- Rotação de segredo = re-executar um workflow.

### Negativos
- Passo de dispatch manual na primeira subida.
- Segredos visíveis para quem administra os GitHub Secrets do repositório.

---

## Próximos Passos

- Aprovado e implementado — ver [ADR-022](../adr/ADR-022-bootstrap-scripts-operacionais.md).
