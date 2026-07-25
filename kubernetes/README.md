# kubernetes/

Manifests da aplicação ServiceTrack e do ArgoCD. Movidos do repositório da API
para cá para ficarem junto da IaC. O deploy é **GitOps**: o Terraform sobe o
ArgoCD e o app-of-apps, e o ArgoCD sincroniza a aplicação a partir deste
diretório. Ninguém roda `kubectl apply` na aplicação.

Decisões em [ADR-012](../docs/adr/ADR-012-gitops-eks-nodeport.md) e
[ADR-013](../docs/adr/ADR-013-chaves-jwt-fora-do-git.md).

## Estrutura

```
kubernetes/
├── argocd/
│   ├── projects/service-track.appproject.yaml   projeto (repos e recursos permitidos)
│   ├── root-app.yaml                            app-of-apps (aplicado pelo Terraform)
│   ├── applications/service-track-prod.*        app de PRD, sincronizado pelo Argo
│   ├── local/service-track-local.*              app do kind, aplicado à mão
│   └── bootstrap/                               instala o Argo no kind (dev)
├── k8s/
│   ├── base/                                    Deployment, Service ClusterIP, namespace
│   └── overlays/
│       ├── prod/   NodePort 30080 + HPA + imagem do ECR
│       └── local/  Postgres + NodePort + chaves de dev
└── kind/cluster.yaml                            cluster local
```

## Fluxo em PRD (EKS)

```
terraform apply
  ├── instala ArgoCD (Helm, modules/addons)
  └── aplica AppProject + root-app  (scripts/argocd-bootstrap-apply.sh)
        └── ArgoCD sincroniza applications/service-track-prod
              └── overlays/prod  →  Deployment + NodePort 30080 + HPA
```

O tráfego externo entra **só pelo API Gateway**:

```
API Gateway → VPC Link → NLB interno → NodePort 30080 → pods
```

Não há LoadBalancer público — a única porta de entrada é o gateway, para que API
key, throttling e WAF não sejam contornados
([ADR-012](../docs/adr/ADR-012-gitops-eks-nodeport.md)).

> **Contrato com a IaC:** o `Service` de prod precisa ser `NodePort 30080`
> (`var.app_node_port`). Se mudar, o NLB fica *unhealthy* e o gateway responde
> 503.

### Pods aparecem no console do ArgoCD?

Sim, agora que o Argo **cria** o Deployment: os pods surgem como recursos-filho
do app na árvore. Antes o deploy era imperativo (`kubectl`), fora do rastreio do
Argo, e por isso os pods não apareciam.

## Dev local (kind)

```bash
kind create cluster --config kubernetes/kind/cluster.yaml
kubectl apply -k kubernetes/argocd/bootstrap                 # instala o Argo no kind
kubectl apply -f kubernetes/argocd/projects/service-track.appproject.yaml
scripts/gen-local-jwt-keys.sh                                # gera as chaves de dev (não versionadas)
kubectl apply -f kubernetes/argocd/local/service-track-local.application.yaml
```

O overlay `local` gera Postgres, chaves JWT de dev e expõe NodePort 30080
(mapeado para `localhost:8080` pelo `kind/cluster.yaml`).

## Chaves JWT

Não são versionadas ([ADR-013](../docs/adr/ADR-013-chaves-jwt-fora-do-git.md)).
Em dev, gere com `scripts/gen-local-jwt-keys.sh`. Em prod, o secret
`service-track-jwt` é entregue fora do git (o AppProject o trata como recurso
órfão ignorado).
