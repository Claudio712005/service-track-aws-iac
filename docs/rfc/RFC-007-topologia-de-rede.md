# RFC-007 — Topologia de rede, rotas e saída para a internet

- **Status:** implementado
- **Data:** 2026-07-31
- **ADR resultante:** [024](../adr/ADR-024-topologia-de-rede-e-tabelas-de-rota.md)

## 1. Problema

A rede foi construída junto com o resto do stack e nunca teve as escolhas registradas. Três
delas parecem erro para quem lê o Terraform sem contexto:

1. Duas AZs, mas **um NAT Gateway só** — assimetria que anula parte da redundância.
2. Uma route table privada para as duas AZs — o padrão de mercado é uma por AZ.
3. Um gateway endpoint de S3 sozinho, sem os endpoints de ECR que costumam vir junto.

As três são deliberadas. Sem registro, a primeira revisão "corrige" a mais barata das três e
dobra o custo do item mais caro da rede.

## 2. Restrições

**Custo.** NAT Gateway é ~US$ 32/mês cada. É o segundo item mais caro do ambiente, atrás só do
control plane do EKS.

**O EKS exige duas AZs.** Não há topologia de uma AZ possível.

**O RDS Multi-AZ de PRD exige duas AZs** para posicionar o standby.

**Ambiente efêmero.** Tudo é recriado a cada apply, inclusive o Elastic IP do NAT — o IP
público de saída muda toda vez.

**Recriação frequente é o caminho quente.** Cada recriação puxa a imagem inteira do ECR. Onde
esse tráfego passa importa mais aqui do que em um ambiente estável.

## 3. Opções avaliadas

### NAT: uma zona contra uma por zona

| | 1 NAT | 1 NAT por AZ |
|---|---|---|
| Custo | ~US$ 32/mês | ~US$ 64/mês |
| Queda de `us-east-1a` | nodes da `1b` perdem internet | isolada por AZ |
| Route tables privadas | 1 | 2, uma por AZ |
| Tráfego entre AZs | pago quando a `1b` sai pelo NAT da `1a` | evitado |

Adotado 1 NAT. O que se perde é resiliência a falha de AZ em um ambiente que fica ligado
algumas horas por semana e cujo SLA é o de um trabalho acadêmico. Dobrar o item mais caro da
rede para cobrir esse cenário não se sustenta.

**As duas mudanças são inseparáveis:** o dia em que houver um NAT por AZ, a route table privada
precisa virar `count = length(var.azs)` no mesmo commit. Fazer só metade produz uma topologia
em que metade do tráfego atravessa a AZ errada, pagando transferência entre zonas — pior que o
estado atual, e silencioso.

### NAT Instance no lugar do NAT Gateway

`t3.nano` como NAT: ~US$ 4/mês contra ~US$ 32. Economia real de ~US$ 28/mês.

Rejeitada: exige AMI mantida, patch, `source_dest_check` desabilitado e monitoração própria.
Vira um ponto de falha que precisa de cuidado em um projeto cujo gargalo é tempo, não dinheiro.

### Subnets privadas sem saída para a internet

Eliminaria o NAT inteiro. Inviável: a aplicação chama FIPE, Unsplash e Resend, e os nodes
precisam do ECR. Só funcionaria com interface endpoints para tudo, que somariam mais que o NAT.

### Endpoints de VPC: quais valem

| Endpoint | Tipo | Custo | Decisão |
|---|---|---|---|
| S3 | Gateway | **zero** | adotado |
| ECR API | Interface | ~US$ 7/mês por AZ | fora |
| ECR DKR | Interface | ~US$ 7/mês por AZ | fora |
| CloudWatch Logs | Interface | ~US$ 7/mês por AZ | fora |

O endpoint de S3 entrou porque é gratuito e porque **as camadas de imagem do ECR são servidas
pelo S3** — o maior volume de tráfego do ambiente deixa de passar pelo NAT, que cobra por GB
processado. Os interface endpoints ficaram de fora: o NAT já está pago, e quatro endpoints em
duas AZs custariam mais que ele.

## 4. Solução adotada

VPC `/16` por ambiente, CIDRs distintos entre HML e PRD, duas AZs, subnets `/20`, um NAT na
primeira AZ, uma route table por camada, gateway endpoint de S3 na route table privada.

Detalhe completo em [ADR-024](../adr/ADR-024-topologia-de-rede-e-tabelas-de-rota.md).

## 5. Riscos conhecidos

| Risco | Mitigação |
|---|---|
| Queda da `us-east-1a` derruba a saída para a internet das duas AZs | Aceito. Correção documentada e de duas linhas |
| Endereço IP de saída muda a cada recriação | Nenhuma integração externa pode depender de allowlist por IP |
| ENIs órfãs do NLB impedem `terraform destroy` da VPC | `scripts/aws-lb-cleanup.sh` antes de destruir |
| Tags do Kubernetes ausentes quebram a criação de load balancer com erro que não menciona tag | Tags declaradas no módulo e documentadas no ADR |

## 6. Evolução possível

- Segundo NAT Gateway e route table privada por AZ, quando o orçamento permitir. **As duas
  juntas.**
- Interface endpoints para ECR API/DKR se o custo de tráfego do NAT superar ~US$ 14/mês, o que
  depende da frequência de recriação.
- Terceira AZ: mudar uma lista, já que subnets e associações usam `count`.
