# ADR – 019: Orquestração com Kubernetes no Amazon EKS

## Data
08/07/2026

Origem: decidida na Fase 2 em `service-track-api` como API-ADR-015, transferida para este
repositório na Fase 3 junto com a propriedade da infraestrutura (`API-ADR-020`,
`GLOBAL-RFC-006`). Conteúdo preservado; apenas a numeração e as referências foram
ajustadas ao esquema deste repositório.

---

## Status

- Aceita

---

## Contexto

A Fase 2 do Tech Challenge exige orquestração com Kubernetes (Deployments, Services,
ConfigMaps/Secrets e HPA), alta disponibilidade e escalabilidade dinâmica para picos de ordens de
serviço. A aplicação já era containerizada (Docker/docker-compose), mas o deploy era um processo
manual sem escala automática nem tolerância a falha de host. O ambiente disponível é o AWS Academy
Learner Lab, que impõe restrições de IAM (uso obrigatório da `LabRole`, sem criação de roles) e
credenciais temporárias.

---

## Decisão

Adotar **Kubernetes gerenciado no Amazon EKS** como plataforma de execução de produção:

- **EKS 1.30** com node group gerenciado (`t3.medium`, desired 2, min 1, max 3) usando a `LabRole`.
- **Multi-AZ:** nós distribuídos em subnets privadas de `us-east-1a` e `us-east-1b`;
  `topologySpreadConstraints` por `topology.kubernetes.io/zone` espalha as réplicas entre zonas.
- **Manifestos com Kustomize** em `infra/k8s/`: `base/` (Deployment, Service, Namespace) e
  `overlays/` (`local` para kind, `prod` para EKS com HPA e Service LoadBalancer).
- **HPA** (`autoscaling/v2`): min 2 / max 10 réplicas, alvo 70% CPU e 80% memória, alimentado pelo
  **metrics-server** (instalado via Terraform/Helm). O campo `replicas` é omitido dos manifestos —
  o HPA é o dono do scale (ver ADR-021 para o tratamento no ArgoCD).
- **Probes HTTP** de startup/readiness/liveness em `/q/health/*` (extensão
  `quarkus-smallrye-health`), com readiness incluindo a checagem do datasource.
- **Exposição** via Service `type: LoadBalancer` (ELB provisionado pelo cloud provider do EKS).
- **Segredos** não versionados: Secrets criados fora do Git (ver ADR-022).

---

## Consequências

### Positivas
- Escalabilidade automática por carga (HPA) atendendo o requisito central da fase.
- Alta disponibilidade: perda de um nó ou de uma AZ inteira não derruba a API.
- Control plane gerenciado pela AWS — sem operar etcd/master.
- Paridade local/prod via overlays (kind localmente, EKS em produção).

### Negativas
- Custo fixo do control plane EKS e dos nós, mesmo em idle.
- `LabRole` impede IRSA (IAM Roles for Service Accounts), limitando integrações nativas
  (ex.: External Secrets Operator) — contornado no ADR-022.
- Sem Cluster Autoscaler/Karpenter no MVP: o número de nós é fixo (2); apenas pods escalam.
  Evolução registrada.

---

## Alternativas Consideradas

### Opção 1: Amazon ECS / Fargate
- Orquestração proprietária AWS, serverless no caso do Fargate.
- Prós: menos operação, sem gerenciar nós.
- Contras: não atende o requisito explícito de manifestos Kubernetes do challenge; menor
  portabilidade.

### Opção 2: Kubernetes autogerenciado em EC2 (kubeadm)
- Prós: controle total, custo menor de serviço.
- Contras: operação do control plane inviável no escopo/tempo do lab; risco alto.

### Opção 3: Apenas kind/minikube (sem cloud)
- Prós: custo zero.
- Contras: não demonstra alta disponibilidade real nem LoadBalancer/multi-AZ; kind ficou como
  ambiente de validação local (ver `infra/GITOPS_LOCAL.md`).

---

## Referências

- [RFC-002 – Orquestração com Kubernetes no EKS](../rfc/RFC-002-kubernetes-eks.md)
- Tech Challenge Fase 2 — `docs/mvp-2/CASE.md` (requisitos de K8s e HPA)
- Manifestos: `infra/k8s/base/`, `infra/k8s/overlays/`
- ADR-020 (Terraform), ADR-021 (GitOps/ArgoCD), ADR-022 (bootstrap e scripts)
