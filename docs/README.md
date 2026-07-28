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

## RFC

- [RFC-001](rfc/RFC-001-arquitetura-de-exposicao-da-api.md) — arquitetura de exposição da API

## Guias

- [api-gateway/README.md](api-gateway/README.md) — guia técnico e operacional
