# kubernetes/

Manifests da aplicação ServiceTrack e do ArgoCD. Movidos do repositório da API
para cá para ficarem junto da IaC. O deploy é **GitOps**: o Terraform sobe o
ArgoCD e a Application do ambiente, e o ArgoCD sincroniza a aplicação a partir
deste diretório. Ninguém roda `kubectl apply` na aplicação.

Decisões em [ADR-012](../docs/adr/ADR-012-gitops-eks-nodeport.md),
[ADR-013](../docs/adr/ADR-013-chaves-jwt-fora-do-git.md),
[ADR-015](../docs/adr/ADR-015-cd-imagem-por-ambiente.md) e
[ADR-016](../docs/adr/ADR-016-seguranca-supply-chain.md).

## Estrutura

```
kubernetes/
├── argocd/
│   ├── projects/service-track.appproject.yaml   projeto (repos e recursos permitidos)
│   ├── applications/service-track-hml.*          app de HML, sincronizado pelo Argo
│   ├── applications/service-track-prod.*         app de PRD, sincronizado pelo Argo
│   ├── local/service-track-local.*               app do kind, aplicado à mão
│   └── bootstrap/                                instala o Argo no kind (dev)
├── k8s/
│   ├── base/                                     Deployment, Service ClusterIP, namespace
│   ├── components/db-init/                       Job de roles do banco (hook PreSync do Argo)
│   └── overlays/
│       ├── hml/    NodePort 30080 + imagem do ECR (servicetrack-hml-app)
│       ├── prod/   NodePort 30080 + HPA + imagem do ECR (servicetrack-prd-app)
│       └── local/  Postgres + NodePort + chaves de dev
└── kind/cluster.yaml                             cluster local
```

HML e PRD são **clusters separados**; cada `terraform apply` aplica só a
Application do seu ambiente (não há app-of-apps, que aplicaria as duas em cada
cluster).

## Fluxo em um ambiente (EKS)

```
terraform apply (env)
  ├── instala ArgoCD (Helm, modules/addons)
  ├── sincroniza secrets do SSM para o cluster  (scripts/app-secrets-bootstrap.sh)
  └── aplica AppProject + service-track-<env>    (scripts/argocd-bootstrap-apply.sh)
        └── ArgoCD sincroniza overlays/<env>
              └── Deployment + NodePort 30080 (+ HPA em prod)
```

O tráfego externo entra **só pelo API Gateway**:

```
API Gateway → VPC Link → NLB interno → NodePort 30080 → pods
```

Não há LoadBalancer público — a única porta de entrada é o gateway, para que API
key, throttling e WAF não sejam contornados
([ADR-012](../docs/adr/ADR-012-gitops-eks-nodeport.md)).

> **Contrato com a IaC:** o `Service` precisa ser `NodePort 30080`
> (`var.app_node_port`). Se mudar, o NLB fica *unhealthy* e o gateway responde
> 503.

### Pods aparecem no console do ArgoCD?

Sim, agora que o Argo **cria** o Deployment: os pods surgem como recursos-filho
do app na árvore. Antes o deploy era imperativo (`kubectl`), fora do rastreio do
Argo, e por isso os pods não apareciam.

## Atualização da imagem (CD)

A CI do repositório da API publica a imagem no ECR (tag = commit SHA) e dispara
o workflow `deploy-image.yml` deste repo, que reescreve o `newTag` do overlay do
ambiente e commita. O ArgoCD sincroniza sozinho. Repositórios ECR são por
ambiente (`servicetrack-hml-app`, `servicetrack-prd-app`), com tags imutáveis e
retenção das últimas 10 imagens. Detalhes em
[ADR-015](../docs/adr/ADR-015-cd-imagem-por-ambiente.md).

## Dev local (kind)

```bash
kind create cluster --config kubernetes/kind/cluster.yaml
kubectl apply -k kubernetes/argocd/bootstrap
kubectl apply -f kubernetes/argocd/projects/service-track.appproject.yaml
scripts/gen-local-jwt-keys.sh
kubectl apply -f kubernetes/argocd/local/service-track-local.application.yaml
```

O overlay `local` gera Postgres, chaves JWT de dev e expõe NodePort 30080
(mapeado para `localhost:8080` pelo `kind/cluster.yaml`).

## Segredos

Não são versionados ([ADR-013](../docs/adr/ADR-013-chaves-jwt-fora-do-git.md)).

- **Dev (kind):** `scripts/gen-local-jwt-keys.sh` gera as chaves; o overlay
  `local` cria os demais secrets com valores placeholder.
- **HML/PRD:** os secrets (`service-track-secret`, `db-init-creds`,
  `service-track-jwt`) vêm do **SSM Parameter Store** (SecureString) e são
  materializados no cluster no apply por `scripts/app-secrets-bootstrap.sh`.
  Popule os parâmetros via `app_secret_params` (chaves: `service-track-secret` e
  `db-init-creds` em formato dotenv; `jwt-private` e `jwt-public` em PEM). Sem
  valores, o passo é ignorado e os secrets seguem sendo entregues fora de banda.
