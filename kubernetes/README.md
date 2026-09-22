# kubernetes/

Plataforma GitOps compartilhada: cluster, ArgoCD e as regras que autorizam
**qualquer** repositório de microsserviço a ser sincronizado nele. Este
diretório **não contém manifesto de nenhuma aplicação** e não cita nenhum
microsserviço pelo nome.

> **Mudança de arquitetura.** Até a Fase 3, este diretório também guardava o
> `k8s/` do monólito e as `Application`s de cada ambiente, uma por uma. Isso
> significava editar este repositório toda vez que um serviço novo entrava no
> cluster. A partir da Fase 4, a descoberta é automática — ver "Como um
> microsserviço novo entra no cluster" abaixo. Os ADRs 012, 013, 015 e 016
> documentam decisões do desenho antigo e continuam válidos como registro
> histórico; não descrevem mais o estado atual deste diretório.

## Estrutura

```
kubernetes/
├── argocd/
│   ├── projects/service-track.appproject.yaml   quais repos e destinos são permitidos
│   ├── templates/application.yaml               molde da Application gerada na descoberta
│   └── bootstrap/                               instala o Argo no kind (dev)
└── kind/cluster.yaml                            cluster local
```

## Como um microsserviço novo entra no cluster

Nenhuma edição neste repositório. O contrato é: **o repositório do
microsserviço carrega `k8s/argocd/<ambiente>.yaml` na branch `main`**. A
presença desse arquivo é o registro — não um nome de repositório nem um
rótulo mantido à mão aqui.

```
terraform apply do ambiente
        │
        ▼
scripts/argocd-bootstrap-apply.sh lista os repositórios do owner no GitHub
        │
        ▼
para cada um com k8s/argocd/<ambiente>.yaml em main:
  templates/application.yaml → Application <repo>-<ambiente>
        │
        ▼
AppProject autoriza: sourceRepos genérico, destination "service-track-*"
        │
        ▼
ArgoCD sincroniza k8s/overlays/<ambiente> do próprio repositório
```

A descoberta roda em **todo** `apply` do ambiente. Repositório novo entra no
próximo `apply`, sem mudança de código aqui.

O owner vem de `GITHUB_OWNER` (padrão `Claudio712005`). A listagem usa
`/users/<owner>/repos`: o gerador `scmProvider` do ArgoCD só aceita
organização, e a conta é pessoal.

## `AppProject`: o que ele autoriza, não o que ele cria

`projects/service-track.appproject.yaml` é genérico de propósito:

- `sourceRepos: ["https://github.com/Claudio712005/*"]` — qualquer
  repositório do owner.
- `destinations: [{namespace: "service-track-*", ...}]` — qualquer namespace
  com esse prefixo, não um nome fixo.

Sem o `*` nos dois campos, a `Application` gerada seria recusada pelo projeto.

## Fluxo em um ambiente (EKS)

```
terraform apply (hml | prd)
  ├── instala ArgoCD + metrics-server (Helm, modules/addons)
  └── scripts/argocd-bootstrap-apply.sh
        ├── aplica o AppProject
        └── gera uma Application por microsserviço descoberto
```

ArgoCD existe nos dois ambientes. Em `prd` a UI fica atrás de um
LoadBalancer (`argocd_expose_lb = true`); em `hml`, só por port-forward.

Isso é **tudo** que este repositório faz pelo GitOps de aplicação. Não há
passo de "atualizar tag do overlay" aqui — cada microsserviço atualiza a
própria tag no próprio repositório.

## Dev local (kind)

```bash
kind create cluster --config kubernetes/kind/cluster.yaml
kubectl apply -k kubernetes/argocd/bootstrap
kubectl apply -f kubernetes/argocd/projects/service-track.appproject.yaml
```

O script de descoberta depende do EKS e não roda no kind. Localmente, cada
microsserviço é registrado a partir do próprio repositório:

```bash
kubectl apply -f <repositorio-do-microsservico>/k8s/argocd/local.yaml
```

> **`gen-local-jwt-keys.sh` foi removido** — gerava chaves para o overlay
> local do monólito, que não existe mais aqui. Geração de chave de
> desenvolvimento é responsabilidade de cada microsserviço, se ele precisar.

## O que este repositório não gerencia mais

- **Manifestos de aplicação** (`Deployment`, `Service`, `HPA`, `ConfigMap`) —
  vivem no repositório de cada microsserviço.
- **Infraestrutura AWS de microsserviço** (ECR, parâmetros SSM) — Terraform
  no próprio repositório do microsserviço, com state próprio no mesmo bucket.
- **Bump de tag de imagem** — cada microsserviço faz isso na própria esteira.
  O workflow `deploy-image.yml` foi removido; existia só para reescrever o
  overlay do monólito.
- **`Application` por ambiente, criada à mão** — substituída pela descoberta
  do `scripts/argocd-bootstrap-apply.sh`.
