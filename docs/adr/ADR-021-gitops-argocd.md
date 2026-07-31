# ADR – 021: Deploy Contínuo GitOps com ArgoCD

## Data
08/07/2026

Origem: decidida na Fase 2 em `service-track-api` como API-ADR-017, transferida para este
repositório na Fase 3 junto com a propriedade da infraestrutura (`API-ADR-020`,
`GLOBAL-RFC-006`). Conteúdo preservado; apenas a numeração e as referências foram
ajustadas ao esquema deste repositório.

---

## Status

- Aceita

---

## Contexto

O primeiro modelo de CD era *push-based*: a pipeline executava um script imperativo
(`deploy-k8s.sh`) que aplicava manifestos direto no EKS via `kubectl`. Problemas: o estado do
cluster divergia do Git sem detecção (sem drift detection), o deploy dependia de credenciais AWS
com acesso total ao cluster dentro da pipeline, não havia rollback declarativo e mudanças manuais
(`kubectl edit`) sobreviviam silenciosamente.

---

## Decisão

Adotar **GitOps pull-based com ArgoCD** como mecanismo de deploy em produção:

- **Instalação:** chart `argo-cd` 7.7.0 via Terraform/Helm (ADR-020), com `server.insecure=true`
  atrás de Service LoadBalancer.
- **AppProject `service-track`:** restringe repositório de origem, namespaces de destino e kinds
  permitidos (whitelist); `orphanedResources.warn` habilitado com `ignore` explícito para os
  recursos criados pelo bootstrap fora do Git (ADR-022).
- **Application `service-track-prod`:** aponta para `infra/k8s/overlays/prod` na branch `main`,
  com `automated: {prune, selfHeal}`, retry com backoff e `CreateNamespace`.
- **HPA como dono do scale:** `ignoreDifferences` em `/spec/replicas` +
  `RespectIgnoreDifferences=true`, evitando que o selfHeal reverta o autoscaling (ADR-019).
- **Pipeline (`cd-app.yml`) reduzida a build + bump:** builda a imagem, publica no ECR e commita
  `kustomize edit set image` no overlay (`[skip ci]` + `paths-ignore` evitam loop). O ArgoCD
  detecta o commit e sincroniza. A pipeline também re-aplica AppProject/Application
  (idempotente) para eliminar dependência de passo manual.
- **Validação local:** o mesmo fluxo roda em kind com a Application `service-track-local`
  (`infra/GITOPS_LOCAL.md`) antes de qualquer mudança em prod.

---

## Consequências

### Positivas
- Git é a única fonte de verdade; drift é detectado e revertido automaticamente (selfHeal).
- Rollback = revert de commit; histórico de deploys = histórico do Git.
- Pipeline não precisa mais de `kubectl apply` do app — menor superfície de credenciais.
- Requisito de CD do challenge atendido de forma declarativa e demonstrável (UI do ArgoCD).

### Negativas
- Componente adicional para operar (ArgoCD: controller, repo-server, redis, server).
- Sincronização eventual (poll ~3 min) — mudanças de manifesto podem aplicar antes/depois do
  bump de imagem correspondente (mitigado agrupando mudanças no mesmo commit).
- Segredos não podem ir ao Git — exige processo complementar (ADR-022).

---

## Alternativas Consideradas

### Opção 1: Push-based com kubectl na pipeline (modelo anterior)
- Prós: simples, um script.
- Contras: sem drift detection/selfHeal, sem rollback declarativo, credenciais de cluster na
  pipeline para todo deploy. Substituída por esta decisão.

### Opção 2: FluxCD
- Prós: GitOps nativo, leve, CRDs simples.
- Contras: sem UI rica — a visualização do ArgoCD tem valor didático/demonstrativo direto na
  apresentação do challenge.

### Opção 3: Helm release por pipeline (helm upgrade no CD)
- Prós: templating poderoso.
- Contras: continua push-based; Kustomize já cobre a variação local/prod com menos abstração.

---

## Referências

- [RFC-004 – GitOps com ArgoCD](../rfc/RFC-004-gitops-argocd.md)
- Manifests: `infra/argocd/` · Pipeline: `.github/workflows/cd-app.yml`
- Runbooks: `infra/GITOPS_AWS.md` (produção), `infra/GITOPS_LOCAL.md` (kind)
- ADR-019 (EKS/HPA), ADR-020 (Terraform), ADR-022 (bootstrap)
