# ADR-026 — Plataforma sem acoplamento a serviços

- **Status:** aceito, parcialmente revogado
- **Data:** 2026-09-22
- **Substitui, no todo ou em parte:** [ADR-003](ADR-003-integracao-backend-eks-vpc-link.md),
  [ADR-012](ADR-012-gitops-eks-nodeport.md), [ADR-015](ADR-015-cd-imagem-por-ambiente.md),
  [ADR-017](ADR-017-acesso-a-aplicacao-apenas-pelo-gateway.md),
  [ADR-022](ADR-022-bootstrap-scripts-operacionais.md) e as regras 1, 2 e 3 do
  [ADR-025](ADR-025-regras-de-security-group.md)
- **Revogado em parte por:** [ADR-033](ADR-033-api-interna-para-o-bff.md) — VPC Link, NLB e
  NodePort voltam, para que o BFF alcance os microsserviços por uma API Gateway privada. A
  regra "nenhum bloco `module` por serviço" continua valendo; a lista de serviços passa a
  existir como dado em `apis/service-track-api-int/`

## Contexto

Até a Fase 3 este repositório era dono do deploy de uma aplicação só, o monólito. Guardava os
manifestos dela, o ECR dela, os segredos dela, o caminho de borda até ela (VPC Link, NLB,
NodePort 30080, 47 rotas no contrato), o agente e os monitores do Datadog desenhados para ela,
e uma esteira que disparava as esteiras dos outros repositórios.

A Fase 4 divide o sistema em microsserviços, cada um com repositório, infraestrutura e banco
próprios. Manter o desenho anterior obrigaria a editar este repositório a cada serviço novo:
rota no contrato, ECR, segredo, `Application`, repositório na lista de credenciais e passo na
orquestração.

## Decisão

Este repositório é plataforma e não cita nenhum microsserviço.

| Fica | Sai |
|---|---|
| Rede, EKS, metrics-server, ArgoCD | manifestos e ECR do monólito |
| `AppProject` genérico e descoberta por marcador (`k8s/argocd/<env>.yaml`) | `Application` por serviço |
| Lambda de autenticação e o ECR dela | segredos do monólito (`app_secret_params`, Unsplash, Resend, `db-init-creds`) e `app-secrets-bootstrap.sh` |
| API Gateway com `POST /autenticacao` | as demais 47 rotas, VPC Link, NLB, NodePort 30080 e o header `x-origem-gateway` |
| Par RS256 gerado no apply; chave pública em `/servicetrack/<env>/jwt-public` | segredo compartilhado do gateway |
| Regra 5432 do RDS a partir da Lambda | regra 5432 a partir dos nodes do EKS |
| — | Datadog: agente, monitores, dashboard, provider e as três secrets `DD_*` |

Consequências no modo de operar:

1. **Infraestrutura de microsserviço vive no repositório do microsserviço**
   (`infra/terraform/`), com state próprio no mesmo bucket. Este repositório não a cria nem a
   destrói.
2. **Nenhuma esteira dispara esteira de outro repositório.** **Subir ambiente** e **Destruir
   ambiente** chamam **Terraform** deste repositório como workflow reutilizável. O banco, a
   Lambda e os microsserviços são operados pelas próprias esteiras; as deste repositório
   conferem os pré-requisitos e falham apontando o que rodar.
3. **Credenciais AWS são propagadas por descoberta**: plataforma fixa (`aws-iac`, `db-infra`,
   `lambda`) mais todo repositório com `k8s/argocd/` ou `infra/terraform/`.
4. **A Lambda continua lendo o RDS do `service-track-db-infra`.** É o único acoplamento que
   sobra entre plataforma e banco, e ele herda a dívida `A-06` (a Lambda lê tabelas escritas
   pelas migrations do monólito). Removê-lo depende de onde a identidade vai morar na divisão
   de `GLOBAL-RFC-009`.

## Alternativas consideradas

- **Proxy genérico (`ANY /{proxy+}`) até um ingress controller no cluster.** Manteria os
  microsserviços alcançáveis pela borda sem rota por serviço. Adiado: exige ingress controller,
  custa o NLB (~US$ 16/mês) e a forma de expor os serviços ainda não foi decidida.
  **Resolvido pelo `ADR-033`**: o caminho escolhido foi `/<servico>/{proxy+}` numa API Gateway
  privada, com VPC Link e NLB, sem ingress controller.
- **Módulo Terraform `microservico` neste repositório, instanciado por serviço.** Rejeitado:
  cada serviço novo viraria um bloco `module` aqui.
- **Manter o Datadog até existir o substituto.** Rejeitado: ele era dimensionado para o
  monólito (monitores de OS, integrações, conexões do banco) e a observabilidade vai migrar
  para Grafana.

## Consequências

- Serviço novo entra no cluster, recebe credencial e tem infraestrutura AWS sem nenhum commit
  aqui.
- **Os microsserviços não são alcançáveis pela borda** até a decisão sobre exposição. Só o
  login é público. *(Decidido no `ADR-033`: alcançáveis por uma API privada, só de dentro da
  VPC. Nada deles passa a ser público.)*
- **Não há observabilidade provisionada.** O requisito de rastreio distribuído da Fase 4 fica
  aberto até a entrada do Grafana.
- Destruir o stack não apaga as imagens dos microsserviços, que vivem em ECR fora deste state.
- `A-06` segue ativo, agora como o único acoplamento plataforma → dado de negócio.
