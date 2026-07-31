# ADR-023 — Dimensionamento de compute por ambiente

- **Status:** aceito
- **Data:** 2026-07-31
- **Origem:** [RFC-006](../rfc/RFC-006-dimensionamento-de-compute.md)

## Contexto

Os dois ambientes rodam o mesmo Deployment, o mesmo Kustomize base e a mesma imagem. O que
muda é o node group:

| | HML | PRD |
|---|---|---|
| `node_instance_types` | `t3.small` | `t3.large` |
| `node_desired_size` | 1 | 2 |
| `node_min_size` | 1 | 2 |
| `node_max_size` | 2 | 4 |
| HPA da aplicação | não existe | 2..10, CPU 70% / memória 80% |
| Datadog cluster agent | 1 réplica | 2 réplicas |

A pergunta que este ADR responde é por que essa diferença específica, e não "PRD é maior
porque é produção".

### As três restrições que decidem o tamanho

**1. A conta é AWS Academy e o ambiente é destruído depois de cada uso.** Isto inverte a
lógica normal de dimensionamento: não se otimiza custo mensal, se otimiza custo por hora
ligada. Ver [ADR-006](ADR-006-ambientes-efemeros-e-conta-educacional.md) e
[ADR-014](ADR-014-estrategia-de-custo-conta-estudante.md).

**2. O limite real de um node do EKS não é CPU nem memória — é endereço IP.** O VPC CNI
atribui um IP da subnet a cada pod, e o número de IPs depende do tipo de instância:

| Tipo | vCPU | Memória | ENIs | IPv4 por ENI | Máximo de pods |
|---|---|---|---|---|---|
| `t3.small` | 2 | 2 GiB | 3 | 4 | **11** |
| `t3.medium` | 2 | 4 GiB | 3 | 6 | 17 |
| `t3.large` | 2 | 8 GiB | 3 | 12 | **35** |

Fórmula do VPC CNI: `ENIs × (IPv4 por ENI − 1) + 2`.

**3. O teto de réplicas está amarrado ao orçamento de conexões do banco**, declarado em
`service-track-db-infra` (`DB-ADR-004`). Aumentar `maxReplicas` sem rever o orçamento faz o
`terraform plan` do banco falhar. Não é um limite de opinião.

## Decisão

### HML: um `t3.small`, sem HPA, teto de 2 nodes

Um `t3.small` entrega 11 slots de pod. O que já ocupa esses slots antes da aplicação:

| Ocupante | Pods |
|---|---|
| `coredns` | 2 |
| `aws-node` (VPC CNI) | 1 |
| `kube-proxy` | 1 |
| `metrics-server` | 1 |
| Datadog node agent + cluster agent | 2 |
| **Subtotal** | **7** |

Sobram **4 slots** para a aplicação. É por isso que **HML não tem HPA**: um HPA com
`maxReplicas: 10` seria ficção — a partir da quinta réplica os pods ficariam `Pending` por
falta de IP, não por falta de CPU, e o sintoma (`0/1 nodes are available: too many pods`) não
se parece nada com o problema. Melhor não declarar autoscaling do que declarar um que não
pode ser cumprido.

Memória confirma a escolha: 2 GiB brutos menos a reserva do kubelet dão cerca de 1,6 GiB
alocável. Com o limite de 512 MiB por pod da aplicação e 512 MiB do node agent do Datadog, 2
réplicas cabem com folga e 3 já apertam.

`node_max_size = 2` existe para sobreviver à perda de um node durante uma apresentação, não
para escalar carga.

### PRD: dois `t3.large`, HPA de 2 a 10, teto de 4 nodes

O salto de `t3.small` para `t3.large` **não compra CPU**: as duas são de 2 vCPU. Compra
memória (2 → 8 GiB) e, principalmente, slots de pod (11 → 35). Com 2 nodes são 70 slots, o que
torna o teto de 10 réplicas do HPA fisicamente possível — que é exatamente o que falta em HML.

Aritmética de CPU no teto do HPA:

```
10 réplicas × 250m de request           = 2500m
2 node agents × 200m + cluster agents   =  600m
kube-system                             = ~400m
                                          ------
                                          3500m

2 × t3.large alocáveis                  ≈ 3860m
```

Cabe, com pouca folga. É por isso que `node_max_size = 4` e não 2: o Cluster Autoscaler
precisa de espaço para responder antes que o HPA fique bloqueado por falta de nó. Passar de 4
não faz sentido — o teto de 10 réplicas já está limitado pelo orçamento de conexões do banco.

`t3.xlarge` foi descartada: dobraria o custo por hora para comprar CPU que o perfil de carga
(picos curtos de abertura de OS, não processamento contínuo) não usa.

### Por que `t3` e não `m5`/`c5`

As `t3` são burstable e têm o menor preço de entrada. O perfil de uso é o de um ambiente que
fica ligado por horas, não semanas, com carga concentrada em demonstração. `m5.large` custa
mais do que o dobro de `t3.large` para entregar a mesma memória.

**Risco assumido:** instâncias `t3` acumulam créditos de CPU e, em modo `unlimited`, cobram
por vCPU excedente quando os créditos acabam. A baseline sustentada é 20% de 2 vCPU na
`t3.small` e 30% na `t3.large`. Uma demonstração longa com carga sintética pode gerar custo
não previsto na tabela abaixo. Não é problema no uso real do projeto, mas é a razão de não se
usar este cluster para teste de carga prolongado.

## Custo

Referência us-east-1, sob demanda, valores aproximados. **Só valem enquanto o ambiente está
ligado** — o mês inteiro nunca acontece, por decisão ([ADR-014](ADR-014-estrategia-de-custo-conta-estudante.md)).

| Item | HML | PRD (mínimo) | PRD (teto) |
|---|---|---|---|
| Nodes | 1 × t3.small ≈ US$ 0,021/h | 2 × t3.large ≈ US$ 0,166/h | 4 × t3.large ≈ US$ 0,333/h |
| Equivalente mensal | ~US$ 15 | ~US$ 120 | ~US$ 240 |

Somado ao control plane (~US$ 73/mês por cluster), NAT (~US$ 32) e NLB (~US$ 16), **PRD ligado
o mês inteiro passa de US$ 240**. É o número que justifica a regra operacional de destruir o
que não está em uso, e o motivo de HML ser o primeiro a cair.

## Consequências

### Positivas

- O tamanho de cada ambiente é derivado de um limite verificável (slots de pod, orçamento de
  conexões), não de preferência.
- A ausência de HPA em HML deixa de ser omissão e passa a ser decisão registrada.
- O custo por hora de cada ambiente é conhecido antes de subir.

### Negativas

- HML não valida comportamento de autoscaling. Um defeito que só aparece com várias réplicas
  — estado em memória, cache local, corrida em job agendado — passa por HML sem sinal e só
  aparece em PRD.
- `t3.large` é folga de memória que não é usada na maior parte do tempo. Aceito: o alternativo
  seria `t3.medium` com 17 slots, que limitaria o HPA a ~6 réplicas por node.

### Impacto em ambiente efêmero

Nada aqui sobrevive a um `destroy`. Ao recriar, o node group nasce em `desired_size` e o
Cluster Autoscaler leva alguns minutos para reagir à primeira carga. Em apresentação, subir o
ambiente com antecedência e gerar tráfego antes de começar.

## Alternativas consideradas

**Mesmo tipo de instância nos dois ambientes.** Simplifica o Terraform e elimina a classe de
defeito "só acontece em PRD". Descartado por custo: HML igual a PRD sairia por ~US$ 120/mês
em um ambiente cuja função é ser barato e descartável.

**Fargate no lugar de node group.** Elimina o problema de slots de pod e o gerenciamento de
node. Descartado porque a `LabRole` do AWS Academy não permite criar os perfis de execução
que o Fargate exige, e porque o custo por pod/hora é maior para carga contínua.

**HPA em HML com `maxReplicas: 3`.** Caberia nos 4 slots. Descartado porque validaria um
comportamento de escala que não se parece com o de PRD, dando falsa confiança — pior do que
não ter.
