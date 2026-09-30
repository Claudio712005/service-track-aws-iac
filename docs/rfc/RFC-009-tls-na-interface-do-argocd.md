# IAC-RFC-009: TLS na interface do ArgoCD exposta

## Data
29/09/2026

## Status
**Em aberto.** Nenhuma decisão tomada. O comportamento atual está descrito em "Situação de hoje"
e continua valendo até esta RFC fechar.

---

## Problema

Com `IAC-ADR-030`, a interface do ArgoCD pode ser exposta por LoadBalancer em qualquer ambiente,
inclusive HML. Ao exercitar isso pela primeira vez, apareceu o seguinte:

- `http://<lb>` responde `200`;
- `https://<lb>` **falha no handshake TLS** (`SSL_ERROR_SYSCALL`, nenhum certificado apresentado);
- a esteira anunciava a URL como `https://`, porque o output montava o esquema à mão.

A causa não é o LoadBalancer nem a rede — subnets públicas com IGW, security group liberando 80 e
443, alvo `InService`. A causa é a combinação de duas escolhas:

| Onde | O que está configurado |
|---|---|
| `modules/addons` | `configs.params.server.insecure = true` (`IAC-ADR-021`) — o `argocd-server` serve **HTTP puro** em 8080 |
| Service do chart | `80 → 8080` e `443 → 8080`; o LoadBalancer é TCP puro, sem terminação |

Ou seja: a porta 443 carrega HTTP em texto claro. Nada termina TLS em ponto nenhum do caminho.

## Consequência que motiva esta RFC

O endereço é **público**, e o login do ArgoCD é usuário e senha em formulário. Sem TLS, a senha do
`admin` — a mesma do secret `ARGOCD_ADMIN_PASSWORD` (`IAC-ADR-028`) — **trafega em texto claro** por
toda a internet no caminho até o LoadBalancer. O mesmo vale para o token de sessão nas requisições
seguintes.

Enquanto o acesso era só por `kubectl port-forward`, isso não aparecia: o tráfego ia por túnel
autenticado do Kubernetes, e o `insecure=true` era irrelevante. A exposição opcional trouxe o
problema à superfície, não o criou.

Vale notar que PRD tem LoadBalancer por padrão desde antes, com a mesma configuração.

## Situação de hoje

A URL correta é `http://<lb>`, e é o que a esteira passa a anunciar. Quem exposer a interface deve
saber que está expondo um formulário de login sem criptografia.

## Alternativas

| # | Alternativa | Prós | Contras |
|---|---|---|---|
| 1 | **Aceitar HTTP e documentar** | zero trabalho; ambiente efêmero e de laboratório | senha de admin em texto claro num endereço público; senha é conhecida e estável entre recriações (`ADR-028`), então vazar é pior do que vazar uma senha descartável |
| 2 | **Desligar `server.insecure`** e deixar o ArgoCD servir o próprio TLS autoassinado, com o LoadBalancer em TCP passthrough | criptografia ponta a ponta sem autoridade certificadora; mudança de uma linha no Helm | aviso de certificado no navegador; `argocd login` exige `--insecure`; alguns clientes recusam |
| 3 | **Terminar TLS no LoadBalancer com certificado ACM**, via anotações no Service | certificado válido, sem aviso | exige domínio e registro DNS; a zona hoje só é usada em PRD (`ADR-008`), e HML não tem nome |
| 4 | **Voltar a expor só por `port-forward`** | nada trafega pela internet | perde o ganho do `ADR-030`, que existe para a apresentação |
| 5 | **Expor por LoadBalancer apenas com IP de origem restrito** (SG com o IP de quem apresenta) | reduz a superfície sem TLS | IP muda, vira trabalho manual a cada sessão; não resolve criptografia, só limita quem alcança |

## Inclinação, sem decisão

A 2 parece a melhor relação entre custo e ganho: resolve o texto claro hoje, sem depender de
domínio, e o aviso de certificado é aceitável para uma interface de operação usada por uma pessoa.
A 3 é a resposta certa para PRD se um dia houver nome para ele. A 1 só é defensável se a senha do
ArgoCD passar a ser descartável por ambiente, o que contraria a intenção do `ADR-028`.

## Para fechar esta RFC é preciso decidir

1. HML e PRD seguem a mesma regra, ou PRD exige certificado válido e HML aceita autoassinado?
2. Se a 2 for escolhida: o `insecure` sai de vez ou passa a ser variável por ambiente?
3. Se a 3 for escolhida: qual nome de DNS para HML, sabendo que a zona é recurso que **sobrevive**
   ao destroy e mora em state separado?
4. Enquanto nada disso existir, a senha do `admin` deve ser rotacionada depois de cada exposição
   pública?

## Referências

- `IAC-ADR-021` — instalação do ArgoCD com `server.insecure=true`
- `IAC-ADR-028` — senha do admin vinda do secret da esteira
- `IAC-ADR-030` — exposição escolhida por execução
