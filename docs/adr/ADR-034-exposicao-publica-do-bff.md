# IAC-ADR-034: a exposição pública do BFF ainda não existe, e por quê

## Data
08/10/2026

## Status
**Aceita, e implementada em 09/10/2026.** A primeira versão deste documento registrava a
omissão deliberada; o responsável pediu a rota, e ela foi construída. O raciocínio de por que
esperar continua abaixo, porque explica o desenho que saiu.

---

## Contexto

O `service-track-bff` é a única entrada pública da plataforma (`GLOBAL-RFC-009`, parte já
respondida). Ele tem imagem, manifestos, NodePort 30083 e esteiras desde 08/10/2026, e está
alcançável **dentro** do cluster.

**Não está alcançável de fora.** O módulo `api-gateway`, que é o gateway público, só conhece
a Lambda: `templatefile` recebe `auth_lambda_uri`, `cors_options` e `bearer_auth_scheme`, e
nada mais. Não há variável de NLB, não há VPC Link, não há integração `http_proxy`.

Expor o BFF exige, no mínimo:

1. variável nova no módulo com o DNS do NLB interno e o identificador do VPC Link;
2. um `${bff_uri}` no `templatefile`, com integração `http_proxy` e `connectionType: VPC_LINK`;
3. uma rota `/{proxy+}` no contrato EXT, que hoje tem **um** path só;
4. fiação disso no módulo `stack`, que é quem conhece os dois lados.

## Decisão

**Não implementar agora.** O contrato EXT **é** o API Gateway: editá-lo altera produção sem
tocar em código de aplicação (`IAC-ADR-002`). Uma integração por VPC Link escrita sem conseguir
rodar `terraform plan` contra uma VPC viva é alteração de produção no escuro.

Três fatos sustentam a espera:

- **`habilitar_borda` está `false`** (`IAC-ADR-027`): o gateway público não está aplicado hoje,
  então a ausência da rota não bloqueia nada que esteja de pé.
- **O NLB interno só existe com `habilitar_api_interna`**, que também está desligada por padrão.
  A rota pública dependeria de um recurso que o ambiente atual não cria.
- **Meia fiação é pior que nenhuma.** Uma rota apontando para um NLB que não existe falha em
  tempo de apply, no meio da subida do ambiente, e o erro aparece longe da causa.

## Consequências

- O BFF é alcançável no cluster e pela API interna de quem está na VPC. Para a demonstração em
  `hml`, o acesso externo sai de `kubectl port-forward` ou do NodePort do nó, não de URL pública.
- **Quando a rota for criada, ela vem pela skill `mudanca-de-contrato`**, com o `plan` rodado
  contra um ambiente que tenha rede e NLB de pé, nessa ordem.
- A lista de serviços da API interna ganhou `ordens` em 30082 (`IAC-ADR-033`). O BFF **não** entra
  nessa lista: a API interna é por onde o BFF chama os outros, não por onde o chamam.

## O que foi construído em 09/10/2026

### O BFF fica atrás do mesmo NLB, sem entrar na API interna

O módulo `api-interna` ganhou uma variável `bff` **separada de `servicos`**. O BFF recebe target
group, listener e regra de entrada no NodePort — tudo no NLB que já existe — e **não** ganha rota
na API interna.

A distinção não é cosmética: a API interna é por onde o BFF chama os outros; quem chama o BFF é o
gateway público. Expor `/bff/{proxy+}` na API interna convidaria um serviço de domínio a chamar o
BFF, invertendo a direção das dependências.

Um segundo NLB e um segundo VPC Link para um único serviço custariam dinheiro numa conta de
estudante sem resolver nada.

### A rota só existe quando há para onde apontar

O módulo `api-gateway` ganhou `bff_integration_uri` e `vpc_link_id`, os dois com padrão nulo.
Nulos, o `templatefile` **não renderiza os paths** — eles desaparecem do contrato em vez de serem
publicados apontando para um NLB que pode não existir.

Isso importa porque `habilitar_borda` e `habilitar_api_interna` são flags independentes: borda
ligada com API interna desligada é combinação possível, e nela não há NLB. Publicar a rota ali
falharia em tempo de apply, no meio da subida, com o erro longe da causa.

Renderização verificada nos dois casos, simulando o `templatefile` e parseando o YAML: com BFF o
contrato tem `/autenticacao`, `/bff` e `/bff/{proxy+}`, todos objetos de path válidos; sem BFF tem
só `/autenticacao`.

### O prefixo `/bff` é removido no caminho

A integração usa `uri = http://<nlb>:30083/{proxy}` com
`integration.request.path.proxy = method.request.path.proxy`, então `/bff/clientes` chega ao
serviço como `/clientes`. O BFF não sabe que está atrás de um prefixo.

### A rota exige chave de API, como a de autenticação

`security: [{ ApiKeyAuth: [] }]` nas duas rotas. O JWT continua sendo validado **pelo BFF**, não
pelo gateway: o authorizer é opcional (`IAC-ADR-005`, `IAC-ADR-007`) e a decisão de quem valida o
token é do serviço.

### Porta 30083, e o par continua sem validação automática

Catálogo 30080, usuários 30081, ordens 30082, BFF 30083. O BFF entrou em
`servicos-<ENV>.yaml` sob a chave `bff`, no mesmo arquivo, porque esta é a única lista deste
repositório que cita microsserviço (`IAC-ADR-033`). O módulo valida faixa, formato do nome e
**colisão de porta com os serviços da API interna** — o que não existia antes.

O que continua sem validação é o par entre esta lista e o manifesto de cada repositório: se o
`k8s/componentes/nodeport` do BFF mudar de porta, nada aqui reclama.

## Pendências que vêm com esta decisão

| Item | Onde | Por que não foi feito |
|---|---|---|
| **`plan` contra ambiente vivo** | esteira `infra.yml` | não havia ambiente de pé nem credencial válida; `validate` e `fmt` passam em todos os diretórios, e a renderização do contrato foi simulada |
| `ST_USU_BASE_URL` na env da Lambda | `iac/modules/stack/main.tf`, via `lambda_extra_env` | `habilitar_autenticacao` está `false`; o valor depende do caminho escolhido (NLB direto ou API interna), que a rota pública também decide |
| `Secret` do Grafana Cloud por ambiente | `iac/modules/stack/` + esteiras dos serviços | `GLOBAL-ADR-009` escolheu Grafana Cloud e o endpoint e token vêm de terceiro, renovados a cada recriação; o desenho é ler do SSM no apply, e não há valor para ler ainda |
