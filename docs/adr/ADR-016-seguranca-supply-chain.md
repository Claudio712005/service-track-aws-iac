# ADR-016 — Segurança da cadeia de entrega da imagem

- **Status:** aceito
- **Data:** 2026-07-24
- **Relaciona:** [ADR-015](ADR-015-cd-imagem-por-ambiente.md), [ADR-012](ADR-012-gitops-eks-nodeport.md), [ADR-013](ADR-013-chaves-jwt-fora-do-git.md)

## Contexto

Com o deploy dirigido por imagem publicada no ECR e sincronizada por GitOps, a
superfície de ataque relevante é a **cadeia de entrega**: quem publica a imagem,
como ela chega ao cluster, e o que impede uma imagem adulterada de rodar. Na
conta de estudante não há orçamento para ferramentas pagas (Inspector avançado,
Signer/Notation gerenciado), então as medidas precisam ser de custo zero.

## Decisões

### 1. Tags imutáveis no ECR

Os repositórios da aplicação são `IMMUTABLE`: uma tag por commit SHA, uma vez
publicada, não pode ser sobrescrita. Fecha o vetor de repush de uma imagem
maliciosa sobre uma tag já validada. O repositório da Lambda fica `MUTABLE`
apenas porque o bootstrap re-publica `:bootstrap` na mesma vida do ambiente.

### 2. Deploy por SHA imutável, auditável no git

A tag que roda em cada ambiente é um commit no git
([ADR-015](ADR-015-cd-imagem-por-ambiente.md)). Não há `:latest` mutável nem
`rollout` fora de banda. Cada deploy tem autor, data e diff; rollback é
`git revert`. A tag é validada (`^[A-Za-z0-9._-]{1,128}$`) antes de entrar no
`sed` do bump.

### 3. Scan no push, gate na origem

`scan_on_push` fica ligado nos repositórios. **O gate é responsabilidade da CI da
API**: ela deve ler os *findings* críticos do scan antes de disparar o
`repository_dispatch`. Este repositório recebe apenas a tag já aprovada — não tem
como (nem deve) reavaliar a imagem, porque não a constrói. Documentado como
pré-requisito no [ADR-015](ADR-015-cd-imagem-por-ambiente.md).

### 4. Token cross-repo de menor privilégio

O único segredo que cruza os dois repositórios é o `IAC_REPO_TOKEN`, com escopo
**`contents: write` apenas neste repositório** — um PAT fino ou GitHub App. Não
dá acesso à AWS, não dá admin. Se vazar, o dano máximo é um commit de bump
(revertível), não acesso à infraestrutura.

### 5. Ponto único de entrada e segredos fora do git

Recapitulando decisões que sustentam a postura:

- **Sem LoadBalancer público** na aplicação: a única porta de entrada é o API
  Gateway, com API key, throttling e WAF ([ADR-012](ADR-012-gitops-eks-nodeport.md)).
- **Chaves e segredos fora do git**, entregues por SSM Parameter Store
  (SecureString) e materializados no cluster no bootstrap
  ([ADR-013](ADR-013-chaves-jwt-fora-do-git.md)).

## O que fica em aberto (aceito para o contexto)

- **Sem assinatura de imagem** (cosign/Notation): custo/complexidade de gestão de
  chaves acima do que o ambiente justifica. A imutabilidade + SHA no git cobrem o
  essencial.
- **Encryption-at-rest dos secrets do k8s** fica no padrão do EKS (sem envelope
  KMS custom): KMS na Academy é limitado.
- **Gate de scan não é imposto tecnicamente** deste lado — depende do processo na
  CI da API. Registrado como responsabilidade explícita.
