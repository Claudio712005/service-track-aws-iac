# ADR-012 — Deploy da aplicação por GitOps e exposição por NodePort

- **Status:** aceito
- **Data:** 2026-07-24
- **Relaciona:** [ADR-003](ADR-003-integracao-backend-eks-vpc-link.md)

## Contexto

Os manifests do Kubernetes e do ArgoCD viviam no repositório da API e foram
movidos para este repositório de IaC (`kubernetes/`). No estado herdado, três
coisas estavam quebradas:

1. **Pods invisíveis no console do ArgoCD.** O deploy vinha sendo feito de forma
   imperativa (o antigo `bootstrap-prod.sh` fazia `kubectl apply` direto). O
   ArgoCD tinha o `Application`, mas os pods criados por fora não eram rastreados
   por ele → não apareciam na árvore do app.
2. **`Application` apontando para o repo errado** (`service-track-api.git`, path
   `infra/k8s/...`), que não é mais onde os manifests estão.
3. **Exposição incompatível com o API Gateway.** O overlay de prod publicava um
   `Service type=LoadBalancer` público, mas o VPC Link
   ([ADR-003](ADR-003-integracao-backend-eks-vpc-link.md)) espera um
   `NodePort 30080`. O caminho gateway→NLB→pod não tinha alvo.

## Decisões

### 1. O deploy passa a ser GitOps de ponta a ponta

O `terraform apply` instala o ArgoCD (Helm) e, uma única vez, aplica o
`AppProject` e a **Application do ambiente** (`service-track-<env>`) via
`scripts/argocd-bootstrap-apply.sh` (um `null_resource` no `modules/stack`). A
partir daí o ArgoCD sincroniza a aplicação a partir do git — ninguém mais roda
`kubectl apply` na aplicação.

Como o Argo passa a **criar** o Deployment, os pods aparecem como recursos-filho
do app na árvore, resolvendo o sintoma na raiz. Defensivamente, o `AppProject`
também passou a listar os kinds filho (`Pod`, `ReplicaSet`, `Endpoints`,
`EndpointSlice`) no `namespaceResourceWhitelist`.

**Por que um passo imperativo (`kubectl`) no meio de IaC declarativa:** os CRDs do
ArgoCD só existem depois que o chart sobe, no mesmo apply. `kubernetes_manifest`
exige o CRD em tempo de `plan` → falharia no primeiro apply. O `null_resource`
"empurra" a Application uma vez; o Argo assume o controle de drift dali em
diante. É o padrão de bootstrap do bootstrapper. Roda só no primeiro apply ou
quando os manifests de bootstrap mudam (trigger por `filesha1`).

### 2. Uma Application por ambiente, não app-of-apps

HML e PRD são **clusters separados**. Um app-of-apps que varresse
`applications/` aplicaria as duas Applications em cada cluster (ambas apontam
para `kubernetes.default.svc`), fazendo o cluster de HML tentar subir o overlay
de PRD e vice-versa. Por isso o bootstrap aplica **só a Application do próprio
ambiente** (`service-track-hml` ou `service-track-prod`), escolhida por
`var.environment`. O app `local` (kind, dev) fica em `kubernetes/argocd/local/` e
é aplicado à mão.

### 3. Exposição por NodePort interno, sem LoadBalancer público

O overlay de prod troca `service-lb.yaml` (LoadBalancer) por
`service-nodeport.yaml` (`NodePort 30080`, casando com `var.app_node_port`). O
`Service ClusterIP` da base permanece para tráfego interno.

Consequência de segurança — e o ponto principal: **a única porta de entrada
externa passa a ser o API Gateway.** Sem LB público, não há como contornar API
key, throttling e WAF batendo direto no serviço. Alinha com o modelo de ponto
único de entrada do [ADR-003](ADR-003-integracao-backend-eks-vpc-link.md).

## Consequências

- `terraform apply` exige **kubectl e AWS CLI** na máquina que aplica (o
  `null_resource`). O CI instala ambos; localmente já costumam existir. A flag
  `bootstrap_argocd_apps=false` desliga o passo.
- Remover o LB público economiza ~US$ 16/mês por ambiente e fecha o bypass do
  gateway.
- O `AppProject` restringe destinos aos namespaces `service-track` e `argocd` e
  os `sourceRepos` a este repositório — um `Application` apontando para outro
  repo é rejeitado pelo Argo.
- O contrato com o cluster continua sendo a porta: o `Service` precisa ser
  `NodePort 30080`. Se divergir, o target group do NLB fica *unhealthy* e o
  gateway responde 503 — a infra sobe, mas a rota morre
  ([ADR-003](ADR-003-integracao-backend-eks-vpc-link.md)).
- O app `local` depende de um cluster kind e de chaves JWT de dev geradas fora do
  git ([ADR-013](ADR-013-chaves-jwt-fora-do-git.md)).
