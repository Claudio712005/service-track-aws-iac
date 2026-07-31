# ADR – 022: Bootstrap de Segredos/Config Dinâmica e Scripts Operacionais

## Data
08/07/2026

Origem: decidida na Fase 2 em `service-track-api` como API-ADR-018, transferida para este
repositório na Fase 3 junto com a propriedade da infraestrutura (`API-ADR-020`,
`GLOBAL-RFC-006`). Conteúdo preservado; apenas a numeração e as referências foram
ajustadas ao esquema deste repositório.

---

## Status

- Aceita

---

## Contexto

O GitOps (ADR-021) exige que tudo que o ArgoCD gerencia esteja no Git — mas parte do estado de
produção **não pode** (segredos: senhas de banco, chaves JWT, API keys) ou **não consegue**
(valores que só existem em runtime: endpoint JDBC do RDS vindo de output do Terraform, hostname do
LoadBalancer usado nos magic links de e-mail — API-ADR-014). A solução padrão de mercado (External
Secrets Operator com AWS Secrets Manager) depende de IRSA, bloqueado pela `LabRole` do AWS
Academy. Além disso, o ambiente de lab exige utilitários repetíveis para credenciais temporárias,
seed de dados e demonstração de escala.

---

## Decisão

Separar explicitamente o que é GitOps do que é **bootstrap imperativo idempotente**, concentrado
em `scripts/` e executável tanto localmente quanto por pipeline:

- **`bootstrap-prod.sh`** (pipeline `bootstrap-prod.yml`, workflow_dispatch; roda 1x após o
  `terraform apply` e a cada rotação de segredo). Provisiona, a partir de GitHub Secrets e
  outputs do Terraform:
  - Secret `service-track-jwt` (chaves RS256) e `service-track-secret` (credenciais de DB por
    role, Resend, Unsplash);
  - Job `service-track-db-init` (`infra/k8s/db-init-job.yaml`) criando os roles
    `flyway_user`/`app_user` no RDS (ADR — Flyway/roles);
  - Service LoadBalancer do app e captura do hostname público;
  - ConfigMap `service-track-runtime` (`DB_JDBC_URL`, `SERVICETRACK_API_BASE_URL`) — consumido
    pelo Deployment via `envFrom`, ao lado do ConfigMap estático versionado;
  - Registro do AppProject/Application no ArgoCD e resumo com URLs/credenciais de demo.
  Todos os recursos criados constam do `orphanedResources.ignore` do AppProject (ADR-021).
- **Scripts locais de apoio:**
  - `aws-student-login.sh` — configura o perfil `aws-student` com as credenciais temporárias do
    Learner Lab;
  - `tf.sh` — wrapper de `terraform -chdir=infra/terraform` com o perfil do lab;
  - `db-seed.sh` — publica o `import.sql` como ConfigMap e roda Job de seed no RDS;
  - `demo-hpa.sh` — gerador de carga autenticada para demonstrar o HPA na apresentação.
- **Pipelines:** `infra.yml` (Terraform plan/apply/destroy), `bootstrap-prod.yml` (este
  bootstrap), `cd-app.yml` (build + bump GitOps — ADR-021), `ci.yml`/`security.yml` (Fase 1).

---

## Consequências

### Positivas
- Nenhum segredo real versionado; Git permanece a fonte de verdade apenas do que é declarável.
- Resolve o problema ovo-galinha do `SERVICETRACK_API_BASE_URL` (o LB nasce com o próprio app).
- Idempotente: re-execução segura para rotacionar segredos ou reconstruir ambiente.
- Compatível com a restrição de IAM do Learner Lab (sem IRSA).

### Negativas
- Passo manual (dispatch) entre `terraform apply` e o primeiro deploy — esquecê-lo deixa os pods
  em CrashLoop (mitigado por aviso no resumo do CD).
- Segredos transitam pela pipeline (GitHub Secrets → kubectl) em vez de um cofre gerenciado.
- Dois "donos" do namespace (ArgoCD + bootstrap) exigem a lista de órfãos ignorados para não
  gerar alarme falso.

---

## Alternativas Consideradas

### Opção 1: External Secrets Operator + AWS Secrets Manager
- Prós: padrão de mercado, rotação nativa, segredo nunca passa pela pipeline.
- Contras: exige IRSA (bloqueado pela `LabRole`). Fica como evolução pós-lab.

### Opção 2: Sealed Secrets (Bitnami)
- Prós: segredo cifrado versionável no Git — 100% GitOps.
- Contras: não resolve os valores dinâmicos (JDBC/base-url); gestão de chave do controller;
  complexidade extra no prazo do challenge.

### Opção 3: Segredos em texto no overlay (como no overlay local)
- Prós: simples.
- Contras: inaceitável em produção; usado apenas no ambiente kind com valores de dev.

---

## Referências

- [RFC-005 – Bootstrap e Scripts Operacionais](../rfc/RFC-005-bootstrap-scripts-operacionais.md)
- Código: `scripts/`, `.github/workflows/bootstrap-prod.yml`, `infra/k8s/db-init-job.yaml`
- Runbook: `infra/GITOPS_AWS.md`
- API-ADR-014 (magic link/base-url), ADR-021 (GitOps), memória Flyway/DB roles
