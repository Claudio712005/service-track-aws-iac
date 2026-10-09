# IAC-ADR-034: a exposição pública do BFF ainda não existe, e por quê

## Data
08/10/2026

## Status
**Proposta.** Registra uma decisão tomada por omissão deliberada, para que a omissão não seja
lida como esquecimento.

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

## Pendências que vêm com esta decisão

| Item | Onde | Por que não foi feito |
|---|---|---|
| rota `/{proxy+}` para o BFF no contrato EXT | `apis/service-track-api-ext/openApi.yaml` | muda produção; exige `plan` contra VPC viva |
| `bff_nlb_dns` e `vpc_link_id` no módulo `api-gateway` | `iac/modules/api-gateway/` | idem |
| `ST_USU_BASE_URL` na env da Lambda | `iac/modules/stack/main.tf`, via `lambda_extra_env` | `habilitar_autenticacao` está `false`; o valor depende do caminho escolhido (NLB direto ou API interna), que a rota pública também decide |
| `Secret` do Grafana Cloud por ambiente | `iac/modules/stack/` + esteiras dos serviços | `GLOBAL-ADR-009` escolheu Grafana Cloud e o endpoint e token vêm de terceiro, renovados a cada recriação; o desenho é ler do SSM no apply, e não há valor para ler ainda |
