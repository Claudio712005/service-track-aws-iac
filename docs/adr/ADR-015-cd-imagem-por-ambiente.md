# ADR-015 — CD por bump de imagem no git, com repositório ECR por ambiente

- **Status:** aceito
- **Data:** 2026-07-24
- **Relaciona:** [ADR-012](ADR-012-gitops-eks-nodeport.md)

## Contexto

A esteira do **repositório da API** compila e publica a imagem no ECR. O ArgoCD,
neste repositório de IaC, sincroniza a aplicação a partir do git — a tag da
imagem fica em `kubernetes/k8s/overlays/<env>/kustomization.yaml`. Faltava o elo:
publicar imagem no ECR não atualizava a tag no git, então o Argo nunca via a
versão nova.

Além disso, HML e PRD compartilhavam um único repositório ECR
(`servicetrack-app`), misturando imagens dos dois ambientes.

## Decisões

### 1. Repositório ECR por ambiente

`servicetrack-hml-app` e `servicetrack-prd-app`, cada um com lifecycle própria
(últimas 10 imagens, expira untagged após 7 dias). Imagens de HML e PRD não se
misturam, e a retenção é independente. Tags **imutáveis**: uma vez publicada, a
tag por commit SHA não pode ser sobrescrita (anti supply-chain).

### 2. Atualização por bump no git (não Image Updater)

A escolha foi entre:

| Opção | Veredito |
|---|---|
| **Bump no git via dispatch** | escolhida |
| ArgoCD Image Updater (poll do ECR no cluster) | descartada |
| `:latest` + `rollout restart` | descartada |

O **bump no git** venceu pela conta de estudante: o workflow que atualiza a tag
(`.github/workflows/deploy-image.yml`) **não usa credencial AWS** — só
`contents: write` no repositório. Como as credenciais da AWS Academy rotacionam a
cada sessão, um mecanismo que depende delas (Image Updater, que precisa ler o
ECR) seria frágil. O bump depende só de um token GitHub, que não expira por
sessão.

Benefícios adicionais: imutabilidade e rastreabilidade (cada deploy é um commit),
rollback trivial (`git revert` do bump), e nenhum componente novo rodando no
cluster.

### 3. Fluxo completo

```
repo da API: push → build → push no ECR (tag = commit SHA)
                                      │ repository_dispatch (image-published)
                                      ▼
repo de IaC: deploy-image.yml
   valida env + tag → sed no overlays/<env>/kustomization.yaml → commit em main
                                      │
                                      ▼
   ArgoCD (selfHeal) sincroniza → novo Deployment → rollout
```

O `deploy-image.yml` também aceita `workflow_dispatch` manual (ambiente + tag),
como saída de emergência ou primeiro deploy.

## Pré-requisitos (lado do repositório da API)

1. A CI tagueia a imagem por **commit SHA** (imutável).
2. Após o push no ECR, dispara `repository_dispatch` para este repositório:

   ```yaml
   - uses: peter-evans/repository-dispatch@v3
     with:
       token: ${{ secrets.IAC_REPO_TOKEN }}
       repository: Claudio712005/service-track-aws-iac
       event-type: image-published
       client-payload: '{"environment":"prd","image_tag":"${{ github.sha }}"}'
   ```

3. `IAC_REPO_TOKEN` é um PAT fino ou GitHub App com escopo **`contents: write`**
   apenas neste repositório. É o único segredo que cruza os dois repos.

## Consequências

- O deploy passa a ser um commit em `main`, feito por uma identidade de CI
  (`servicetrack-ci`) — auditável no histórico.
- A tag inicial dos overlays (`latest` em HML, um SHA fixo em PRD) é placeholder
  até o primeiro `image-published`; enquanto isso os pods podem ficar em
  `ImagePullBackOff` se a tag não existir no ECR. É esperado no primeiro deploy.
- Segurança do gatilho: `repository_dispatch` é autenticado pelo token do
  emissor. Só quem tem o `IAC_REPO_TOKEN` dispara. A tag é validada
  (`^[A-Za-z0-9._-]{1,128}$`) antes de entrar no `sed`.
- O gate de vulnerabilidade (scan do ECR) é responsabilidade da CI da API: ela
  deve checar os *findings* antes de disparar o dispatch. Este repositório só
  recebe a tag já aprovada. Ver [ADR-016](ADR-016-seguranca-supply-chain.md).
