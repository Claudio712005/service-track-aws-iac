# Documentação

## ADRs

| # | Decisão |
|---|---|
| [001](adr/ADR-001-api-gateway-rest-vs-http.md) | API Gateway REST (v1) em vez de HTTP (v2) |
| [002](adr/ADR-002-openapi-como-definicao-do-gateway.md) | O OpenAPI é a definição do gateway |
| [003](adr/ADR-003-integracao-backend-eks-vpc-link.md) | Lambda por rota e EKS via VPC Link + NLB — **substituída pelo 026** |
| [004](adr/ADR-004-fronteira-ext-terraform.md) | Fronteira entre o EXT e o Terraform |
| [005](adr/ADR-005-autorizacao-jwt-no-backend.md) | JWT no backend, API Key controla consumo *(revisado pelo 007)* |
| [006](adr/ADR-006-ambientes-efemeros-e-conta-educacional.md) | Ambientes efêmeros e conta educacional |
| [007](adr/ADR-007-lambda-authorizer-opcional.md) | Lambda authorizer de JWT como recurso opcional |
| [008](adr/ADR-008-dominio-customizado-opcional.md) | Domínio customizado com base path — **revogada em 02/08/2026** |
| [009](adr/ADR-009-multiplas-api-keys-por-consumidor.md) | Uma API key por consumidor |
| [010](adr/ADR-010-contract-testing-na-pipeline.md) | Contract testing em duas camadas |
| [011](adr/ADR-011-rate-limiting-defesa-em-camadas.md) | Rate limiting e defesa em camadas na borda |
| [012](adr/ADR-012-gitops-eks-nodeport.md) | Deploy por GitOps e exposição por NodePort — **substituída pelo 026** |
| [013](adr/ADR-013-chaves-jwt-fora-do-git.md) | Chaves JWT fora do git |
| [014](adr/ADR-014-estrategia-de-custo-conta-estudante.md) | Estratégia de custo na conta de estudante |
| [015](adr/ADR-015-cd-imagem-por-ambiente.md) | CD por bump de imagem, repositório ECR por ambiente — **substituída pelo 026** |
| [016](adr/ADR-016-seguranca-supply-chain.md) | Segurança da cadeia de entrega da imagem |
| [017](adr/ADR-017-acesso-a-aplicacao-apenas-pelo-gateway.md) | Acesso à aplicação apenas pelo API Gateway — **substituída pelo 026** |
| [018](adr/ADR-018-segredos-gerados-no-apply.md) | Segredos gerados no apply, não colados em secrets |
| [019](adr/ADR-019-kubernetes-eks.md) | Orquestração com Kubernetes no Amazon EKS |
| [020](adr/ADR-020-terraform-iac.md) | Infraestrutura como código com Terraform |
| [021](adr/ADR-021-gitops-argocd.md) | Deploy contínuo GitOps com ArgoCD |
| [022](adr/ADR-022-bootstrap-scripts-operacionais.md) | Bootstrap de segredos e scripts operacionais — **substituída pelo 026** |
| [023](adr/ADR-023-dimensionamento-de-compute-por-ambiente.md) | Dimensionamento de compute por ambiente, e por que HML não tem HPA |
| [024](adr/ADR-024-topologia-de-rede-e-tabelas-de-rota.md) | Topologia de rede, tabelas de rota e saída para a internet |
| [025](adr/ADR-025-regras-de-security-group.md) | Regras de security group e a fronteira entre states *(regras 1 a 3 revogadas pelo 026)* |
| [026](adr/ADR-026-plataforma-sem-acoplamento-a-servicos.md) | Plataforma sem acoplamento a serviços (Fase 4) |
| [027](adr/ADR-027-autenticacao-e-borda-desligadas-por-flag.md) | Autenticação e borda desligadas por flag |
| [028](adr/ADR-028-senha-do-argocd-por-secret-da-esteira.md) | Senha do admin do ArgoCD vem do secret da esteira |
| [029](adr/ADR-029-conta-aws-derivada-de-quem-esta-logado.md) | Nenhum identificador de conta AWS escrito no código |
| [030](adr/ADR-030-exposicao-do-argocd-escolhida-por-execucao.md) | Exposição do ArgoCD escolhida na execução da esteira |

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
- [RFC-009](rfc/RFC-009-tls-na-interface-do-argocd.md) — TLS na interface do ArgoCD exposta **(em aberto)**

## Diagramas

- [diagramas/arquitetura-aws.drawio](diagramas/arquitetura-aws.drawio) — arquitetura dos dois
  ambientes: borda, VPC, EKS, RDS, esteira de entrega e legenda. Abrir em diagrams.net.
  **Descreve a Fase 3** (monólito, VPC Link, NLB, Datadog); não reflete o `IAC-ADR-026`.
- [acoplamentos.md](acoplamentos.md) — o que o desenho mostra mas não explica: NodePort 30080,
  inversão do ArgoCD, segredos fora do Git, HPA medido contra `requests`, SG do NLB.
- [api-gateway/README.md](api-gateway/README.md) — guia técnico e operacional
