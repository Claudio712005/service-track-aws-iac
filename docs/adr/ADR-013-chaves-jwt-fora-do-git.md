# ADR-013 — Chaves JWT fora do git

- **Status:** aceito
- **Data:** 2026-07-24

## Contexto

A aplicação assina e verifica JWT com um par RS256. Ao mover os manifests do
Kubernetes para este repositório, o overlay `local` (kind) trouxe junto um par de
chaves em `kubernetes/k8s/overlays/local/keys/*.pem`, consumido por um
`secretGenerator` do kustomize.

Chave privada em repositório é um risco: quem tem acesso ao repo assina tokens
válidos.

## Situação verificada

As chaves estavam apenas na árvore de trabalho — **nunca foram commitadas nem
enviadas ao remoto** (`kubernetes/` inteiro estava *untracked*, e o `.gitignore`
já continha `*.pem`). Não houve exposição no histórico do git; não foi preciso
reescrever histórico.

As chaves de **produção** não são estas: o overlay de prod só define o *caminho*
onde a aplicação lê a chave (`SMALLRYE_JWT_SIGN_KEY_LOCATION`), e o secret
`service-track-jwt` é entregue fora do git (o `AppProject` o trata como recurso
órfão ignorado). As chaves versionáveis por engano eram, portanto, só as de dev.

## Decisão

1. **Nenhuma chave no git.** O `.gitignore` bloqueia `*.pem`; confirmado que nem
   `git add kubernetes/` as inclui.
2. **Chaves de dev são geradas sob demanda** por `scripts/gen-local-jwt-keys.sh`
   (par RS256 novo em `overlays/local/keys/`, não versionado). São descartáveis:
   valem só para o cluster kind local.
3. **Chaves de prod continuam externas ao git**, entregues em runtime via o
   secret `service-track-jwt` (mesmo caminho já usado pela Lambda de autenticação
   por `lambda_extra_env.MP_JWT_VERIFY_PUBLICKEY`).

## Consequências

- Preparar o ambiente local passa a exigir um passo: `scripts/gen-local-jwt-keys.sh`
  antes de `kubectl kustomize overlays/local`. Documentado no
  [kubernetes/README.md](../../kubernetes/README.md).
- `kubectl kustomize overlays/local` falha se as chaves não existirem — o que é o
  comportamento correto: falha explícita em vez de subir com chave versionada.
- Como as chaves de dev nunca saíram da máquina, não há necessidade de rotação.
  Se em algum momento uma chave de dev tiver sido usada em ambiente real, gere um
  par novo com `FORCE=true` e rotacione o consumidor.
- A entrega dos secrets de HML/PRD passou a ser reprodutível via **SSM Parameter
  Store** (SecureString), materializados no cluster no apply por
  `scripts/app-secrets-bootstrap.sh` a partir de `app_secret_params`. O material
  fica no SSM (cifrado), não no git; `terraform apply` reconstrói o vínculo. Ver
  [ADR-016](ADR-016-seguranca-supply-chain.md).
