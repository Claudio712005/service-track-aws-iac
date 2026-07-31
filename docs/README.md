# Documentação

## ADRs

| # | Decisão |
|---|---|
| [001](adr/ADR-001-api-gateway-rest-vs-http.md) | API Gateway REST (v1) em vez de HTTP (v2) |
| [002](adr/ADR-002-openapi-como-definicao-do-gateway.md) | O OpenAPI é a definição do gateway |
| [003](adr/ADR-003-integracao-backend-eks-vpc-link.md) | Lambda por rota e EKS via VPC Link + NLB |
| [004](adr/ADR-004-fronteira-ext-terraform.md) | Fronteira entre o EXT e o Terraform |
| [005](adr/ADR-005-autorizacao-jwt-no-backend.md) | JWT no backend, API Key controla consumo *(revisado pelo 007)* |
| [006](adr/ADR-006-ambientes-efemeros-e-conta-educacional.md) | Ambientes efêmeros e conta educacional |
| [007](adr/ADR-007-lambda-authorizer-opcional.md) | Lambda authorizer de JWT como recurso opcional |
| [008](adr/ADR-008-dominio-customizado-opcional.md) | Domínio customizado opcional com base path |
| [009](adr/ADR-009-multiplas-api-keys-por-consumidor.md) | Uma API key por consumidor |
| [010](adr/ADR-010-contract-testing-na-pipeline.md) | Contract testing em duas camadas |
| [011](adr/ADR-011-rate-limiting-defesa-em-camadas.md) | Rate limiting e defesa em camadas na borda |
| [012](adr/ADR-012-gitops-eks-nodeport.md) | Deploy por GitOps e exposição por NodePort |
| [013](adr/ADR-013-chaves-jwt-fora-do-git.md) | Chaves JWT fora do git |
| [014](adr/ADR-014-estrategia-de-custo-conta-estudante.md) | Estratégia de custo na conta de estudante |
| [015](adr/ADR-015-cd-imagem-por-ambiente.md) | CD por bump de imagem, repositório ECR por ambiente |
| [016](adr/ADR-016-seguranca-supply-chain.md) | Segurança da cadeia de entrega da imagem |
| [017](adr/ADR-017-acesso-a-aplicacao-apenas-pelo-gateway.md) | Acesso à aplicação apenas pelo API Gateway |
| [018](adr/ADR-018-segredos-gerados-no-apply.md) | Segredos gerados no apply, não colados em secrets |
| [019](adr/ADR-019-kubernetes-eks.md) | Orquestração com Kubernetes no Amazon EKS |
| [020](adr/ADR-020-terraform-iac.md) | Infraestrutura como código com Terraform |
| [021](adr/ADR-021-gitops-argocd.md) | Deploy contínuo GitOps com ArgoCD |
| [022](adr/ADR-022-bootstrap-scripts-operacionais.md) | Bootstrap de segredos e scripts operacionais |
| [023](adr/ADR-023-dimensionamento-de-compute-por-ambiente.md) | Dimensionamento de compute por ambiente, e por que HML não tem HPA |
| [024](adr/ADR-024-topologia-de-rede-e-tabelas-de-rota.md) | Topologia de rede, tabelas de rota e saída para a internet |
| [025](adr/ADR-025-regras-de-security-group.md) | Regras de security group e a fronteira entre states |

`019` a `022` foram decididos na Fase 2 dentro de `service-track-api`, como `API-ADR-015` a
`API-ADR-018`, e transferidos para cá na Fase 3 junto com a propriedade da infraestrutura
(`GLOBAL-RFC-006`). O conteúdo é o original; mudou a numeração, que colidia com `015` a `018`
deste repositório.

## RFC

- [RFC-001](rfc/RFC-001-arquitetura-de-exposicao-da-api.md) — arquitetura de exposição da API
- [RFC-002](rfc/RFC-002-kubernetes-eks.md) — Kubernetes no EKS
- [RFC-003](rfc/RFC-003-terraform-iac.md) — infraestrutura como código com Terraform
- [RFC-004](rfc/RFC-004-gitops-argocd.md) — GitOps com ArgoCD
- [RFC-005](rfc/RFC-005-bootstrap-scripts-operacionais.md) — bootstrap de segredos
- [RFC-006](rfc/RFC-006-dimensionamento-de-compute.md) — dimensionamento de compute por ambiente
- [RFC-007](rfc/RFC-007-topologia-de-rede.md) — topologia de rede, rotas e saída para a internet
- [RFC-008](rfc/RFC-008-regras-de-security-group.md) — regras de security group

## Diagramas

- [diagramas/rede.md](diagramas/rede.md) — topologia de VPC, subnets, NAT e o caminho do
  tráfego até o pod
- [diagramas/deployment.md](diagramas/deployment.md) — mapeamento software → nó de execução,
  fluxo de imagem e de segredos

Ambos descrevem o estado da Fase 3. Os desenhos equivalentes da Fase 2 estão em
`service-track-api/docs/mvp-2/infra-fase-2/` e descrevem o cluster `servicetrack-dev`, que não
existe mais.

## Guias

- [api-gateway/README.md](api-gateway/README.md) — guia técnico e operacional
