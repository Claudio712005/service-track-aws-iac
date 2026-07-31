# ADR-024 — Topologia de rede, tabelas de rota e saída para a internet

- **Status:** aceito
- **Data:** 2026-07-31
- **Origem:** [RFC-007](../rfc/RFC-007-topologia-de-rede.md)

## Contexto

A rede vive em state próprio (`iac/network/<env>`), aplicado antes do banco e do stack. Ver
[ADR-003](ADR-003-integracao-backend-eks-vpc-link.md) e `DB-ADR-003` para a fronteira.

Endereçamento por ambiente:

| | HML | PRD |
|---|---|---|
| VPC | `10.10.0.0/16` | `10.20.0.0/16` |
| Públicas | `10.10.0.0/20`, `10.10.16.0/20` | `10.20.0.0/20`, `10.20.16.0/20` |
| Privadas | `10.10.48.0/20`, `10.20.64.0/20` | `10.20.48.0/20`, `10.20.64.0/20` |
| AZs | `us-east-1a`, `us-east-1b` | `us-east-1a`, `us-east-1b` |

CIDRs distintos por ambiente são deliberados: permitem peering ou VPN entre eles no futuro sem
renumerar. `/20` dá 4091 IPs utilizáveis por subnet — muito acima do necessário, mas o custo de
um bloco grande é zero e o de renumerar depois é um `destroy`.

## Decisão

### 1. Duas AZs nos dois ambientes, inclusive em HML

Não é redundância; é requisito. O EKS **recusa criar o control plane** com subnets em uma única
AZ, e o RDS Multi-AZ de PRD precisa de duas para posicionar o standby. Manter HML com duas AZs
também evita que HML e PRD tenham topologias diferentes, o que tornaria HML inútil como ensaio.

O custo de uma AZ extra é zero enquanto não há recurso nela. As subnets são criadas com
`count = length(var.azs)`, então acrescentar uma terceira AZ é mudar uma lista.

### 2. Um único NAT Gateway, na primeira AZ

Esta é a concessão de custo mais relevante da rede, e precisa estar explícita:

```
NAT Gateway     ~US$ 32/mês cada, + tráfego processado
1 NAT           ~US$ 32/mês
1 NAT por AZ    ~US$ 64/mês
```

**O que se perde:** a route table privada é única e aponta `0.0.0.0/0` para o NAT da
`us-east-1a`. Se a `us-east-1a` cair, os nodes da `us-east-1b` continuam recebendo tráfego do
NLB, mas **perdem a saída para a internet**. Na prática isso derruba: consulta à FIPE, busca de
imagem no Unsplash, envio de e-mail pelo Resend e o pull de imagem do ECR.

**Por que é aceitável aqui:** o ambiente é destruído depois de cada uso e o SLA prometido é o de
um trabalho acadêmico. Pagar o dobro para sobreviver à queda de uma AZ em um ambiente que fica
ligado algumas horas por semana não se sustenta. A alternativa correta em produção real —
um NAT por AZ e uma route table privada por AZ — está descrita em [RFC-007](../rfc/RFC-007-topologia-de-rede.md)
e é uma mudança de duas linhas quando o orçamento permitir.

### 3. Uma route table por camada, não por AZ

| Route table | Associada a | Rota padrão |
|---|---|---|
| `<name>-public-rt` | as 2 subnets públicas | `0.0.0.0/0` → Internet Gateway |
| `<name>-private-rt` | as 2 subnets privadas | `0.0.0.0/0` → NAT Gateway (AZ *a*) |

Uma route table por camada é consequência direta da decisão anterior: com um único NAT, não há
o que diferenciar entre as rotas das duas AZs privadas. No dia em que houver um NAT por AZ, a
route table privada precisa virar `count = length(var.azs)` **junto** — as duas mudanças são
inseparáveis, e separá-las produz uma topologia em que metade do tráfego atravessa a AZ errada
pagando transferência entre zonas.

### 4. Gateway endpoint de S3 na route table privada

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}
```

Gateway endpoints **não têm custo** — nem por hora, nem por GB. O ganho é duplo: o tráfego para
o S3 deixa de passar pelo NAT (que cobra por GB processado) e deixa de sair da VPC.

Importa mais do que parece porque **as camadas de imagem do ECR são servidas pelo S3**. Cada
recriação de ambiente puxa a imagem da aplicação inteira, e sem o endpoint isso é tráfego pago
no NAT toda vez. Em um projeto cujo modo normal de operação é destruir e recriar, esse é o
caminho mais percorrido da rede.

Não existe equivalente gratuito para ECR API, ECR DKR ou CloudWatch: esses são interface
endpoints, que custam ~US$ 7/mês cada por AZ. Ficaram de fora — o NAT já está pago.

### 5. Subnets públicas com `map_public_ip_on_launch` e tags do Kubernetes

```
públicas:  kubernetes.io/role/elb           = 1
privadas:  kubernetes.io/role/internal-elb  = 1
ambas:     kubernetes.io/cluster/<cluster>  = shared
```

Sem essas tags o AWS Load Balancer Controller não descobre onde criar load balancer, e o erro
que aparece (`could not find any suitable subnets`) não menciona tag nenhuma. É configuração
de rede que existe para um consumidor de fora do módulo — está documentada aqui porque é
invisível em qualquer outro lugar.

`map_public_ip_on_launch = true` nas públicas existe para que o NAT Gateway e qualquer recurso
de borda recebam IP público automaticamente. **Nenhum node do EKS roda em subnet pública** — o
node group usa apenas as privadas.

### 6. O que fica em cada camada

| Camada | Recursos |
|---|---|
| Pública | Internet Gateway, NAT Gateway, Elastic IP |
| Privada | node group do EKS, ENIs da Lambda de autenticação, NLB interno do VPC Link, instância RDS |
| Fora da VPC | API Gateway, ECR, SSM Parameter Store |

O API Gateway é o único ponto público do sistema. Não há Load Balancer público para a
aplicação — o NLB é `internal = true`. Ver [ADR-017](ADR-017-acesso-a-aplicacao-apenas-pelo-gateway.md)
para por que a rede sozinha não fecha esse acesso.

## Consequências

### Positivas

- Custo de rede fixo e conhecido: ~US$ 32/mês de NAT por ambiente ligado, mais o NLB.
- Endpoint de S3 corta o item de tráfego que mais cresce em ambiente recriado com frequência.
- Topologia idêntica entre HML e PRD: o que funciona em um funciona no outro.

### Negativas

- **Ponto único de falha na saída para a internet.** Documentado acima, aceito, com o caminho
  de correção escrito.
- Uma route table por camada não permite política de rota diferente por AZ. Não é necessário
  hoje; passa a ser no dia do segundo NAT.
- Sem interface endpoints, todo o tráfego para ECR API e CloudWatch atravessa o NAT e é pago
  por GB.

### Impacto em ambiente efêmero

VPC, subnets, route tables e o Elastic IP do NAT são recriados a cada apply. **O IP público de
saída muda toda vez** — nenhuma integração externa pode depender de allowlist por IP. O
`scripts/aws-lb-cleanup.sh` precisa rodar antes do `destroy`, senão ENIs órfãs do NLB impedem a
remoção da VPC.

## Alternativas consideradas

**NAT Instance no lugar de NAT Gateway.** Uma `t3.nano` como NAT custaria ~US$ 4/mês contra
~US$ 32. Descartado: exige AMI, gerenciamento de patch, `source_dest_check` desabilitado e vira
um ponto de falha que precisa de monitoração própria. Troca US$ 28/mês por trabalho operacional
em um projeto cujo gargalo é tempo, não dinheiro.

**Subnets privadas sem saída para a internet.** Eliminaria o NAT inteiro (~US$ 32/mês).
Inviável: a aplicação chama FIPE, Unsplash e Resend, e os nodes precisam do ECR. Só funcionaria
com interface endpoints para tudo, que custariam mais que o NAT.

**Uma AZ só em HML.** Economizaria zero — não há recurso pago por AZ na configuração atual — e
o EKS recusaria criar o cluster. Descartado por ser impossível, não por custo.
