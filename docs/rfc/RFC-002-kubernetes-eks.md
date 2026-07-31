# RFC – 002: Orquestração com Kubernetes no Amazon EKS

## Data
08/07/2026

Origem: decidida na Fase 2 em `service-track-api` como API-RFC-015, transferida para este
repositório na Fase 3 junto com a propriedade da infraestrutura (`API-ADR-020`,
`GLOBAL-RFC-006`). Conteúdo preservado; apenas a numeração e as referências foram
ajustadas ao esquema deste repositório.

---

## Status
- Encerrada – Aprovada

---

## Resumo

Proposta de adoção do Amazon EKS como plataforma de orquestração da ServiceTrack API, com
manifestos Kustomize (base + overlays), HPA para escala automática e distribuição multi-AZ,
atendendo os requisitos de infraestrutura da Fase 2.

---

## Problema

O deploy da Fase 1 era um container único orquestrado por docker-compose:

- Sem escala automática — picos de ordens de serviço degradam o tempo de resposta (SRS exige ≤ 2s).
- Sem tolerância a falha de host: queda da VM/nó = indisponibilidade total (SRS exige 99% uptime).
- Rollout manual, sem histórico nem rollback.
- O challenge da Fase 2 exige explicitamente manifestos Kubernetes com Deployment, Service,
  ConfigMap/Secret e HPA.

---

## Proposta Técnica

1. **Cluster:** EKS 1.30 (`servicetrack-dev`, us-east-1), node group gerenciado `t3.medium`
   (2 nós, min 1 / max 3) em subnets privadas de duas AZs; `LabRole` como cluster/node role
   (restrição do AWS Academy).
2. **Manifestos (Kustomize):**
   - `infra/k8s/base/` — Namespace, Deployment (probes HTTP `/q/health/*`, resources
     250m/256Mi–512Mi, `topologySpreadConstraints` por zona, envFrom ConfigMaps + Secret),
     Service ClusterIP.
   - `infra/k8s/overlays/local/` — kind: Postgres in-cluster, NodePort, secrets de dev.
   - `infra/k8s/overlays/prod/` — EKS: HPA (min 2 / max 10, CPU 70% / memória 80%),
     Service LoadBalancer, ConfigMap estático, imagem apontando para o ECR.
3. **Métricas:** metrics-server via Helm (Terraform), requisito do HPA.
4. **Scale:** campo `replicas` omitido do Deployment/kustomization — HPA é a única fonte do
   número de réplicas.
5. **Validação local:** cluster kind (`infra/kind/cluster.yaml`) reproduz o fluxo completo antes
   do EKS.

---

## Alternativas Consideradas

### Opção 1: ECS/Fargate
- Orquestração AWS sem gerenciar nós.
- Prós: operação mínima.
- Contras: não cumpre o requisito de manifestos K8s; lock-in.

### Opção 2: Kubernetes autogerenciado (kubeadm em EC2)
- Prós: controle e custo de serviço menores.
- Contras: operar control plane no prazo do lab é inviável e arriscado.

### Opção 3: Somente ambiente local (kind)
- Prós: custo zero.
- Contras: não demonstra HA/LB/multi-AZ reais; mantido apenas como ambiente de validação.

---

## Pontos em Aberto

- Cluster Autoscaler/Karpenter para escalar nós (hoje fixo em 2) — evolução.
- Ingress + ALB Controller no lugar de Service LoadBalancer — evolução.

---

## Impactos

### Positivos
- HPA atende "escalabilidade dinâmica em horários de pico" do challenge.
- Falha de nó/AZ sem downtime perceptível; rollout com histórico e rollback.

### Negativos
- Custo de control plane + 2 nós contínuos.
- Curva de operação de K8s para o time.

---

## Próximos Passos

- Aprovado e implementado — ver [ADR-019](../adr/ADR-019-kubernetes-eks.md).
