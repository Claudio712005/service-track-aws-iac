# RFC – 004: Deploy Contínuo GitOps com ArgoCD

## Data
08/07/2026

Origem: decidida na Fase 2 em `service-track-api` como API-RFC-017, transferida para este
repositório na Fase 3 junto com a propriedade da infraestrutura (`API-ADR-020`,
`GLOBAL-RFC-006`). Conteúdo preservado; apenas a numeração e as referências foram
ajustadas ao esquema deste repositório.

---

## Status
- Encerrada – Aprovada

---

## Resumo

Proposta de migração do deploy push-based (script imperativo com kubectl na pipeline) para GitOps
pull-based com ArgoCD: o Git passa a ser a fonte única do estado do cluster e a pipeline se limita
a build de imagem e bump de tag.

---

## Problema

Com o `deploy-k8s.sh` na pipeline:

- Mudanças manuais no cluster não eram detectadas nem revertidas (drift invisível).
- Rollback exigia reexecutar pipeline antiga; sem trilha declarativa do que está no ar.
- A pipeline carregava credenciais com poder total de `kubectl apply` a cada deploy.
- Os manifestos flat duplicavam o que já existia em `base/overlays` (Kustomize), com risco de
  divergência entre caminhos local e prod.

---

## Proposta Técnica

1. **ArgoCD in-cluster** (chart 7.7.0 via Terraform), UI exposta por LoadBalancer para
   demonstração; acesso alternativo por port-forward.
2. **AppProject** com whitelist de repo/namespaces/kinds e alerta de recursos órfãos (ignorando
   os segredos do bootstrap, deliberadamente fora do Git).
3. **Application prod**: `overlays/prod@main`, auto-sync com `prune` + `selfHeal`, retry/backoff,
   `ignoreDifferences` em `spec.replicas` (HPA manda no scale) com `RespectIgnoreDifferences`.
4. **Pipeline nova (`cd-app.yml`)**: build → push ECR → `kustomize edit set image` → commit
   `[skip ci]` no overlay (com `paths-ignore` anti-loop) → ArgoCD sincroniza. Passo idempotente
   re-aplica AppProject/Application e publica resumo (URLs, status do app, credencial de demo).
5. **Fluxo local espelhado** em kind com Application própria, validando manifestos antes de prod.
6. **Remoção do caminho legado**: `deploy-k8s.sh` e manifestos flat deletados.

---

## Alternativas Consideradas

### Opção 1: Manter push-based (kubectl na pipeline)
- Prós: já funcionava.
- Contras: sem selfHeal/drift/rollback declarativo; mais credencial exposta. Rejeitada.

### Opção 2: FluxCD
- Prós: mais leve.
- Contras: sem UI para demonstração do fluxo na banca. Rejeitada para este contexto.

### Opção 3: ArgoCD Image Updater (bump automático sem commit da pipeline)
- Prós: elimina o commit de bump.
- Contras: mais um componente e credencial de escrita no repo dentro do cluster; adiado.

---

## Pontos em Aberto

- Sealed Secrets / External Secrets para os segredos hoje bootstrapados (ver RFC-005).
- App-of-apps se o número de aplicações crescer.

---

## Impactos

### Positivos
- Estado do cluster auditável pelo Git; demo visual de sync/self-heal na apresentação.
- Rollback trivial (git revert).

### Negativas
- Latência de sincronização (poll) entre push e deploy.
- Operação de mais um componente no cluster.

---

## Próximos Passos

- Aprovado e implementado — ver [ADR-021](../adr/ADR-021-gitops-argocd.md).
