# IAC-ADR-033: API Gateway privada entre o BFF e os microsserviços

## Data
03/10/2026

## Status
Aceita. Revoga a parte do [`IAC-ADR-026`](ADR-026-plataforma-sem-acoplamento-a-servicos.md) que
removeu VPC Link, NLB e NodePort, e resolve a alternativa que ele havia adiado ("proxy genérico
até o cluster"). O resto do `IAC-ADR-026` continua valendo.

---

## Contexto

Depois do `IAC-ADR-026` os microsserviços são `Service type=ClusterIP` em subnet privada, sem
nenhum caminho de entrada. Isso é correto enquanto não há cliente externo, e deixa de ser no
momento em que o BFF da Fase 4 precisa chamá-los.

Havia duas formas de o BFF alcançar um serviço:

| Caminho | Como é |
|---|---|
| **Direto no cluster** | `http://service-track-catalogo.service-track-catalogo.svc.cluster.local` — um salto, sem infraestrutura nova, sem custo |
| **Pelo gateway** | BFF → API Gateway → VPC Link → NLB → NodePort → pod |

**A recomendação técnica era a primeira**, e está registrada aqui porque não foi a escolhida: o
BFF roda no mesmo cluster, DNS do Kubernetes já resolve, e o gateway no meio de uma chamada
interna adiciona latência e uma dependência externa a um caminho que não precisa dela.

A decisão do responsável pelo projeto foi a segunda, com dois motivos: ter o caminho de borda
(gateway, VPC Link, NLB, NodePort) exercitado e demonstrável, e ter um ponto único onde política
de acesso, log e futuras regras de WAF se aplicam a chamada de serviço — não só à borda pública.
A decisão é essa, e este ADR a registra.

O requisito que **não** muda: nenhum microsserviço pode ser alcançado da internet. O endereço
existe para o BFF, não para o público.

## Decisão

Criar o módulo `iac/modules/api-interna`: uma **segunda** API Gateway, com
`endpoint_configuration.types = ["PRIVATE"]`, que roteia `/<servico>/{proxy+}` para os pods por
VPC Link.

```
BFF (no cluster)
  → endpoint de interface do execute-api (na VPC, DNS privado)
    → API Gateway privada, stage "interna"
      → VPC Link
        → NLB interno
          → NodePort do serviço
            → pod
```

Quatro controles somados fazem com que esse endereço não seja público:

1. **Endpoint `PRIVATE`.** API Gateway privada não tem nome resolvível na internet. Só responde
   através de um endpoint de interface na VPC.
2. **Política de recurso na API**: `Deny` em `execute-api:Invoke` para todo
   `aws:sourceVpce` diferente do nosso endpoint, seguido de `Allow`. Mesmo quem conseguisse
   resolver o nome é negado na autorização. Ela vai **dentro** do corpo OpenAPI, em
   `x-amazon-apigateway-policy`, e não como `aws_api_gateway_rest_api_policy` separado: a API é
   definida por `body`, e `PutRestApi` em modo `overwrite` zera a política de recurso — com a
   política no corpo, ela é reescrita no mesmo instante em que as rotas são.
3. **NLB `internal = true`**, em subnet privada, sem endereço público.
4. **O NodePort só aceita tráfego do security group do NLB** — não da VPC inteira, não do
   bloco do nó.

A lista de serviços é **dado, não código**:
`apis/service-track-api-int/servicos-<ENV>.yaml`. O módulo é genérico e recebe
`nome`, `nodePort` e `saude`. Serviço novo entra editando esse arquivo.

Ligada por flag: `habilitar_api_interna`, **`false` por padrão**, no mesmo estilo de
`habilitar_autenticacao` e `habilitar_borda` (`IAC-ADR-027`).

## O que isto custa

| Item | Por mês, ambiente ligado o mês inteiro | Com 3 h/dia |
|---|---|---|
| NLB (1 LCU mínimo) | ~US$ 16,20 | ~US$ 2,00 |
| Endpoint de interface (1 ENI por AZ, 2 AZs) | ~US$ 14,60 | ~US$ 1,80 |
| API Gateway REST, requisições | US$ 3,50 por milhão | desprezível |

Cerca de **US$ 4 por mês** no padrão de uso real. O caminho direto no cluster custaria zero —
é o preço da decisão, e ele é pequeno.

## Consequências

- **O `IAC-ADR-026` passa a ter uma exceção, e ela é nomeada.** Este repositório volta a citar
  microsserviço, em um lugar só: `apis/service-track-api-int/servicos-<ENV>.yaml`. Módulo
  nenhum conhece nome de serviço. A regra "nenhum bloco `module` por serviço" continua de pé.
- **O par porta/serviço vive em dois repositórios e nada o valida.** Cada entrada no YAML exige
  um `Service type=NodePort` na mesma porta no `k8s/` do serviço. Divergência não falha o
  `apply`: aparece como alvo `unhealthy` no target group. É a fragilidade real desta decisão.
- **Não há WAF nesta API.** A AWS não associa WebACL a API Gateway privada. A regra de SQL
  injection do `IAC-ADR-032` protege a borda pública — hoje `/autenticacao`, amanhã o BFF —, e
  **não** protege esta chamada. Quem chama aqui é o nosso BFF, com entrada já filtrada na borda.
- **O gateway entra no caminho crítico interno.** Indisponibilidade dele derruba chamada entre
  serviços que o DNS do cluster resolveria sozinho. Aceito deliberadamente.
- **Latência**: um salto a mais, na casa de poucas dezenas de milissegundos, e o teto de 29 s de
  integração do API Gateway passa a valer para chamada interna.
- **`scripts/aws-lb-cleanup.sh` mudou.** Ele apagava todo ELB da VPC antes do `destroy`; agora
  preserva o que tem `ManagedBy=terraform`, porque apagar o NLB por fora deixaria o VPC Link
  apontando para nada. LoadBalancer criado pelo Kubernetes continua sendo apagado.
- Dois novos recursos no caminho de `destroy`. VPC Link leva alguns minutos para sumir; é
  esperado, e o Terraform respeita a ordem (VPC Link antes do NLB).
- **A escolha é por execução, e não fica lembrada** — mesmo mecanismo do `IAC-ADR-030`: a
  esteira recebe `api_interna` como `padrao`, `sim` ou `nao`, e `padrao` vale o padrão do
  ambiente, que é `false`. Aplicar com `padrao` depois de ter aplicado com `sim` **destrói** a
  API interna. É a mesma armadilha da exposição do ArgoCD, e a mesma mitigação: a escolha
  aparece no log da execução.
- A URL da API interna é **output e parâmetro SSM**
  (`/servicetrack/<env>/api-interna/base-url`), nunca constante: ela muda a cada recriação,
  como tudo o mais (`GLOBAL-ADR-002`).

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| **BFF chama o serviço direto por DNS do cluster** | era a recomendação: zero custo, zero infra, um salto. Não escolhida — o projeto quer o caminho de borda exercitado e um ponto único de política |
| API pública com restrição por IP ou API key | o requisito é não ser alcançável da rede pública; chave e IP restringem quem entra, não deixam de ter porta aberta |
| Ingress controller com NLB interno, sem gateway | mais uma peça para manter e nenhum ganho sobre DNS do cluster, que já existe de graça |
| `VPC_LINK` em HTTP API (v2) em vez de REST | HTTP API não tem endpoint privado; o equivalente seria API pública com autorizador |
| Uma API só, com as rotas públicas e as internas juntas | a mesma API não é pública e privada ao mesmo tempo; `endpoint_configuration` é da API inteira |
| `Service type=LoadBalancer` interno por serviço | um NLB por serviço, custo multiplicado por serviço |
