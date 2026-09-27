# IAC-ADR-028: senha do admin do ArgoCD vem do secret da esteira

## Data
27/09/2026

## Status
Aceita.

---

## Contexto

A senha inicial do `admin` do ArgoCD é gerada pelo próprio bootstrap e guardada no secret
`argocd-initial-admin-secret`. Como os ambientes aqui são destruídos e recriados o tempo todo,
isso significa: **senha diferente a cada recriação**, sempre buscada com um `kubectl get secret`
antes de qualquer acesso à interface. É um dos itens da lista de "o que não sobrevive a um
destroy".

O incômodo não é a senha ser aleatória — é ela não ser conhecida de antemão. Quem vai
demonstrar o ambiente precisa fazer uma consulta ao cluster antes de conseguir entrar, e o
roteiro de demonstração não pode citar credencial nenhuma.

## Decisão

Se `ARGOCD_ADMIN_PASSWORD` estiver no ambiente, o `scripts/argocd-bootstrap-apply.sh` grava o
hash bcrypt dela em `argocd-secret`, apaga o `argocd-initial-admin-secret` e reinicia o
`argocd-server`. A esteira Terraform exporta essa variável a partir do secret de mesmo nome do
*environment* do GitHub, apenas no passo de `apply`.

Sem a variável, o comportamento é o de antes: senha gerada, e o script diz no log como lê-la.

## Consequências

- A senha passa a ser **conhecida e estável** entre recriações. O roteiro de demonstração
  continua sem citar o valor — ele está no secret do GitHub, não em documento.
- **A senha não entra no state do Terraform.** Ela chega ao `local-exec` por herança de
  ambiente do processo, não como variável Terraform. Foi o motivo de não declarar uma
  `variable` para ela: isso a gravaria no state em S3, que é a exposição descrita em `I-16`.
- O hash bcrypt é gerado por `htpasswd` quando disponível, e por um contêiner `httpd:2-alpine`
  como alternativa. Faltando os dois, o script **avisa e segue**: bootstrap não falha por causa
  de senha de interface.
- O `argocd-initial-admin-secret` é removido, então não sobra credencial antiga válida nem
  dúvida sobre qual das duas vale.
- Trocar a senha depois é rodar o `apply` de novo com o secret novo. Não há caminho manual
  escondido.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| `argocd account update-password` pela CLI | exige instalar a CLI e **fazer login com a senha atual**, que é justamente a que ninguém sabe ainda |
| Variável Terraform com a senha | gravaria o segredo no state em S3, piorando `I-16` para ganhar nada |
| Desligar o usuário local e usar SSO | o IAM Identity Center está bloqueado na conta educacional (verificado por sonda) |
| Deixar como estava | obriga uma consulta ao cluster antes de cada acesso, em ambiente que é recriado toda hora |
