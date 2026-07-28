# ADR – 017: Acesso à aplicação apenas pelo API Gateway

## Data
28/07/2026

---

## Status

- Aceita

---

## Contexto

A aplicação no EKS é exposta por `Service type: NodePort` na porta 30080, e o caminho oficial
é API Gateway → VPC Link → NLB interno → NodePort. Não existe LoadBalancer público, e os nodes
estão em subnets privadas: **da internet a aplicação já era inalcançável fora do gateway.**

O problema estava dentro da VPC. A regra que libera o NodePort tinha
`cidr_blocks = [var.vpc_cidr]`: apesar do nome `nodes_from_nlb`, qualquer coisa na VPC —
outro pod, a Lambda de autenticação, um node comprometido — alcançava a aplicação direto.

Isso importa porque o gateway é o **único lugar** onde existem API key, quota, throttling e
validação de request por JSON Schema. Furar o gateway não é chegar na aplicação por outro
caminho: é perder todos esses controles de uma vez.

O `@RateLimit` da aplicação não substitui, porque é **por pod**. Com o HPA em dez réplicas,
`POST /clientes` sai de 10/min para 100/min.

Duas restrições descobertas ao desenhar a solução:

1. O target group usa `target_type = "instance"`, onde o NLB **preserva o IP do cliente** por
   padrão. Com preservação ligada, a origem que chega ao node é o cliente original, e não o
   NLB — então não há como referenciar o security group do NLB na regra do node.
2. As ENIs do VPC Link **não têm security group referenciável**. O NLB precisa aceitar tráfego
   delas, e a única forma de expressar isso é por CIDR.

A consequência da segunda restrição é que **a rede sozinha não fecha o acesso**: ela move o
desvio de `node:30080` para `nlb:80`.

---

## Decisão

**Duas camadas, e a de aplicação é a que fecha.**

### 1. Rede — reduzir a superfície

- O NLB ganha security group próprio.
- `preserve_client_ip = false` no target group, para que a origem no node seja o NLB. Nada se
  perde: o IP real do usuário continua chegando pelo `X-Forwarded-For` do API Gateway.
- A regra do NodePort passa a usar `source_security_group_id` apontando para o SG do NLB, em
  vez de liberar a VPC inteira.

Isso elimina o acesso direto ao NodePort. O NLB segue alcançável na porta 80 de dentro da VPC,
porque as ENIs do VPC Link não são referenciáveis.

### 2. Aplicação — fechar de fato

O gateway injeta `x-origem-gateway` em **todas** as 48 integrações `http_proxy`, via
`requestParameters`. O mapeamento **sobrescreve** o valor que o cliente enviar, então não há
como forjar de fora.

A aplicação recusa com `403` qualquer requisição sem o header correto, exceto nos caminhos de
plataforma (`/q/health`, `/q/metrics`, `/q/openapi`, `/q/swagger-ui`) — sem essa isenção os
probes do Kubernetes falhariam e nenhum pod ficaria pronto.

O segredo é gerado por ambiente pelo Terraform quando não informado, publicado em
`/servicetrack/<env>/gateway/shared-secret` no SSM e entregue à aplicação como secret do
Kubernetes. Segredo vazio desliga o filtro, que é o comportamento desejado em desenvolvimento
local.

---

## Consequências

### Positivas
- O acesso direto ao NodePort deixa de existir.
- Requisição que chegue ao NLB por fora do gateway é recusada pela aplicação.
- API key, quota, throttling e validação de schema voltam a ser inescapáveis.
- O segredo é rotacionado sozinho a cada recriação de ambiente, sem intervenção.

### Negativas
- É segredo compartilhado na configuração da aplicação: se a aplicação for comprometida, ele
  vaza junto. Não é fronteira de segurança por si só.
- Mais um valor a entregar no bootstrap. Se faltar, o filtro fica desligado e o script avisa.
- A lista de caminhos isentos precisa acompanhar qualquer rota de plataforma nova.
- `preserve_client_ip = false` significa que a aplicação nunca vê o IP de origem na camada de
  rede. Aceito porque o `X-Forwarded-For` do gateway já traz o do usuário.
- Security group em NLB só pode ser definido na **criação**. Ambientes existentes precisam ser
  recriados — o que aqui é rotina.

### Impacto em ambiente efêmero
Favorável. O segredo nasce novo a cada ambiente e a restrição do NLB, que normalmente exigiria
recriar o balanceador, sai de graça porque todo ambiente nasce novo.

---

## Alternativas Consideradas

### Opção 1: Só a regra de rede
Rejeitada: não fecha. As ENIs do VPC Link não são referenciáveis por security group, então o
NLB continua alcançável de dentro da VPC.

### Opção 2: Subnets dedicadas para o NLB
Colocar NLB e ENIs do VPC Link em subnets exclusivas e restringir o SG do NLB a esses CIDRs
fecharia pela rede, sem segredo compartilhado.
Não adotada agora: exige mudar o módulo de rede e mais duas subnets por ambiente. É a evolução
natural se o segredo compartilhado se mostrar incômodo.

### Opção 3: mTLS entre gateway e aplicação
Rejeitada: o NLB é L4 e a perna gateway→NLB exigiria TLS ponta a ponta, com gestão de
certificados a cada recriação. Peso alto para o ganho sobre a opção adotada.

### Opção 4: NetworkPolicy no cluster
Rejeitada por ora: cobre a mesma ameaça que a regra de security group, com mais superfície
operacional.
