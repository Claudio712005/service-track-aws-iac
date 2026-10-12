# ADR-035: nenhum microsserviço é alcançável por gateway, exceto o BFF

## Data
12/10/2026

## Status
Aceita. **Supera a parte de exposição da [`ADR-033`](ADR-033-api-interna-para-o-bff.md)**, que
criava uma API Gateway privada com rota por microsserviço. A `ADR-034` continua valendo: a rota
pública `/bff` existe e é por VPC Link.

---

## Contexto

A `ADR-033` criou uma segunda API Gateway, com endpoint `PRIVATE`, expondo
`/<servico>/{proxy+}` para cada microsserviço, para o BFF chamá-los. A recomendação técnica
registrada naquele ADR era o contrário — DNS do cluster — e foi vencida pela decisão do
responsável.

**O código nunca usou a API privada.** O overlay do BFF em `hml` e `prd` aponta para o DNS do
cluster:

```
ST_BFF_CATALOGO_URL=http://service-track-catalogo.service-track-catalogo.svc.cluster.local
ST_BFF_ORDENS_URL=http://service-track-ordens.service-track-ordens.svc.cluster.local
ST_BFF_USUARIOS_URL=http://service-track-usuarios-veiculos.service-track-usuarios-veiculos.svc.cluster.local
```

Então a API privada, as rotas por serviço, o endpoint de interface do `execute-api` e a lista de
serviços existiam sem consumidor — e, existindo, davam a cada microsserviço um caminho de entrada
por gateway que ninguém pediu.

## Decisão

**Só o BFF fica atrás de gateway. Nenhum outro microsserviço tem rota em gateway nenhum.**

O que sai:

| Recurso | Por quê |
|---|---|
| REST API privado, deployment e stage | não tinha consumidor, e dava rota de entrada a cada serviço |
| `aws_vpc_endpoint` do `execute-api` e seu security group | existiam só para o REST API privado |
| Rotas `/<servico>` e `/<servico>/{proxy+}` | idem |
| Target group, listener e regra de ingress por serviço | nada roteia para eles |
| Variável `servicos` do módulo, `servicos_internos` no stack | sem consumidor |
| Parâmetro SSM `api-interna/base-url` e os quatro outputs da API interna | idem |

O que fica, porque a rota pública `/bff` depende: **NLB interno, target group do BFF, listener,
regra de ingress do NodePort 30083 e VPC Link.**

### A Lambda é a exceção, e ela não passa por gateway

A Lambda de autenticação chama `POST /credenciais/verificacao` no `usuarios-veiculos` para
conferir a credencial antes de emitir o token. Ela **roda na VPC, não no cluster**, então não
resolve DNS de `ClusterIP` — o caminho por DNS que o BFF usa não serve para ela.

A `ADR-034` já registrava isso como pendência: o valor de `ST_USU_BASE_URL` "depende do caminho
escolhido (NLB direto ou API interna)". Removendo a API interna, **sobra o NLB direto**, e é essa
a decisão:

| Quem | Alcança | Por onde |
|---|---|---|
| Borda pública | BFF (30083) | VPC Link → NLB |
| Lambda de autenticação | `usuarios-veiculos` (30081) | **NLB direto**, sem gateway |
| BFF | catálogo, usuários, ordens, checkout | DNS do cluster |

**Isso não viola a decisão deste ADR**: o `usuarios-veiculos` ganha um listener no NLB e
**nenhuma rota em gateway**. NLB é balanceador, não gateway, e a porta só aceita tráfego do
security group dele.

O alvo só existe com `habilitar_autenticacao = true` — sem Lambda ninguém chama a verificação. E
`ST_USU_BASE_URL` passa a ser **injetada pelo stack** a partir do DNS do NLB, em vez de depender
de alguém preencher `lambda_extra_env` à mão. **Essa variável nunca esteve ligada**: o Terraform
não a definia em lugar nenhum, e a Lambda caía no default `http://localhost:8080`. Autenticação
nunca funcionou em `hml` por esse motivo, independente deste ADR.

**Consequência de flag:** `habilitar_autenticacao = true` passa a exigir
`habilitar_entrada_do_bff = true`, porque sem NLB não há caminho até a verificação.

### A flag foi renomeada porque passou a mentir

`habilitar_api_interna` → **`habilitar_entrada_do_bff`**. Ela não cria mais API nenhuma: cria o
NLB e o VPC Link que a borda usa. O módulo `api-interna` virou `entrada-do-bff`, e o bloco
`module "api_interna"` virou `module "entrada_do_bff"`.

**O endereço no state muda com isso**, e o Terraform vai planejar destruir e recriar NLB, security
groups, target group e VPC Link. Em ambiente efêmero isso não custa nada, e a flag está desligada
por padrão — na prática não há state para migrar. Num ambiente de longa duração a troca exigiria
`moved` blocks.

### `habilitar_borda` passa a exigir esta flag, de verdade

A rota `/bff` só é renderizada quando `bff_integration_uri` e `vpc_link_id` não são nulos, e os
dois vêm deste módulo. Borda ligada com a entrada do BFF desligada entrega um gateway com apenas
`POST /autenticacao` — que é um estado válido, e agora é o único jeito de ter borda sem BFF.

### O catálogo de serviços passa a citar só o BFF

`apis/service-track-api-int/servicos-<ENV>.yaml` tinha quatro serviços e o BFF. Agora tem só o
BFF. A regra da `ADR-033` — "este repositório cita microsserviço em um arquivo só" — continua
valendo, e o arquivo encurtou.

## Consequências

- **Entrada pública da plataforma: duas rotas e nada mais.** `POST /autenticacao`, pela Lambda, e
  `/bff` mais `/bff/{proxy+}`, pelo VPC Link. É o que a `ADR-034` descreve, e agora não há um
  segundo gateway ao lado.
- **O par porta/NodePort deixa de ser contrato entre repositórios** para catálogo (30080),
  ordens (30082) e checkout (30084): este repositório não cita mais essas portas. Sobram dois
  pares: BFF em 30083 e `usuarios-veiculos` em 30081, este último só para a Lambda.
- **Os componentes `nodeport` de catálogo, ordens e checkout ficaram sem consumidor.** Um
  NodePort sem quem o chame é porta aberta no nó sem função. O do `usuarios-veiculos` **fica**,
  porque a Lambda depende dele.
- **Um recurso cobrado a menos**: o endpoint de interface do `execute-api` tinha custo por hora
  por AZ.
- **O BFF perde o caminho por gateway que nunca usou.** Se algum dia a chamada precisar sair do
  cluster, a decisão volta à mesa — e volta como ADR, não como flag esquecida ligada.
- **A `ADR-033` fica parcialmente superada.** O que sobrevive dela: NLB interno existe, é privado,
  e o nome do serviço aparece num arquivo só.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Manter a API privada desligada por padrão | é o estado de hoje, e foi o que permitiu quatro microsserviços terem rota de entrada que ninguém revisou. Flag desligada não é desenho, é adiamento |
| Manter a API privada e mover o BFF para ela | o BFF é chamado pela borda pública, não pelo cluster; ele não é cliente da API interna |
| Manter os target groups dos serviços sem rota | custo zero e opção preservada, mas deixa alvo de NLB para quem não é alcançado por ninguém, e uma regra de ingress por porta no SG dos nodes |
| Remover o NLB também e integrar a borda direto no NodePort | API Gateway não integra em NodePort sem VPC Link, e VPC Link exige NLB |
| Manter o nome `habilitar_api_interna` | o nome descreveria algo que o módulo deixou de fazer. Nome errado em flag de infraestrutura é o tipo de dívida que este repositório paga caro |
