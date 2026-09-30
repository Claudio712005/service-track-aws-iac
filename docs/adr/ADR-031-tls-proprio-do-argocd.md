# IAC-ADR-031: o ArgoCD serve o próprio TLS

## Data
29/09/2026

## Status
Aceita. Revoga a parte do [`IAC-ADR-021`](ADR-021-gitops-argocd.md) que fixava
`server.insecure=true`.

---

## Contexto

Com o `IAC-ADR-030`, a interface do ArgoCD passou a poder ser exposta por LoadBalancer em qualquer
ambiente. Na primeira exposição real, `https://<lb>` falhou no handshake TLS e só `http://<lb>`
respondia.

O LoadBalancer e a rede estavam corretos: scheme `internet-facing`, subnets públicas com rota para
o IGW, security group liberando 80 e 443, alvo `InService`. A causa eram duas escolhas somadas:

| Onde | O que havia |
|---|---|
| `modules/addons` | `configs.params.server.insecure = true`, do `IAC-ADR-021` — o `argocd-server` servia **HTTP puro** na 8080 |
| Service do chart | `80 → 8080` **e** `443 → 8080`, com LoadBalancer em TCP puro, sem terminação |

A porta 443 carregava HTTP em texto claro. Nada terminava TLS em ponto nenhum do caminho.

O `insecure=true` fazia sentido quando o acesso era só por `kubectl port-forward`: o tráfego ia por
túnel autenticado do Kubernetes e a criptografia do servidor era redundante. Deixou de fazer
sentido no instante em que o endereço passou a ser público — porque o login do ArgoCD é usuário e
senha em formulário, e a senha do `admin` é **conhecida e estável entre recriações**
(`IAC-ADR-028`). Senha estável trafegando em texto claro por endereço público é exposição real, não
teórica. PRD, que tem LoadBalancer por padrão, estava na mesma situação desde antes.

## Decisão

Remover `configs.params.server.insecure` do Helm. O `argocd-server` volta ao comportamento padrão:
serve TLS na 8080 com **certificado autoassinado** que ele mesmo gera, e responde requisição HTTP
simples na mesma porta com redirecionamento para HTTPS.

O LoadBalancer segue em TCP puro, sem terminação: o que ele transporta agora é TLS de ponta a
ponta, do navegador até o pod.

O output `argocd_url` continua anunciando `https://`, que passa a ser verdade.

## Consequências

- **A senha deixa de trafegar em texto claro.** É o ponto todo.
- **O navegador avisa sobre o certificado.** Autoassinado não tem cadeia de confiança; é aceitar o
  aviso uma vez por sessão. Para a CLI: `argocd login <lb> --insecure`.
- `http://<lb>` continua funcionando, agora como redirecionamento para HTTPS.
- Nada muda para quem usa `kubectl port-forward`, que segue sendo o caminho sem custo e sem
  LoadBalancer.
- **Certificado válido continua em aberto.** Resolver o aviso exige nome de DNS e certificado ACM,
  com terminação no LoadBalancer. HML não tem nome, e a zona é recurso que sobrevive ao destroy, em
  state separado. Não vale abrir esse caminho para uma interface de operação usada por uma pessoa;
  vale reabrir se a interface passar a ser usada por mais gente ou por automação externa.
- O `IAC-ADR-021` continua valendo em tudo menos nesta linha. Está anotado lá.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Aceitar HTTP e documentar o risco | senha estável e conhecida em texto claro num endereço público; documentar não cifra nada |
| Terminar TLS no LoadBalancer com certificado ACM | exige domínio e registro DNS; HML não tem nome, e a zona vive em state separado de propósito |
| Voltar a expor apenas por `port-forward` | desfaz o `IAC-ADR-030`, que existe para a apresentação |
| Restringir a origem no security group ao IP de quem apresenta | o IP muda a cada sessão, vira trabalho manual, e limitar quem alcança não cifra o que trafega |
| Ingress com controller e certificado | peça nova para manter, para expor uma interface interna |
