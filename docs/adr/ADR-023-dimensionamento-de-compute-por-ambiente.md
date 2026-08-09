# ADR-023 — Dimensionamento de compute por ambiente

- **Status:** aceito
- **Data:** 2026-07-31
- **Revisado em:** 2026-08-02 — PRD redimensionado para a apresentação da Fase 3
- **Origem:** [RFC-006](../rfc/RFC-006-dimensionamento-de-compute.md)

## Contexto

Os dois ambientes rodam o mesmo Deployment, o mesmo Kustomize base e a mesma imagem. O que
muda é o node group:

| | HML | PRD |
|---|---|---|
| `node_instance_types` | `t3.small` | `t3.medium` |
| `node_desired_size` | 1 | 1 |
| `node_min_size` | 1 | 1 |
| `node_max_size` | 1 | 2 |
| HPA da aplicação | não existe | 2..4, CPU 70% / memória 80% |
| Datadog cluster agent | 1 réplica | 1 réplica |

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
| `t3.medium` | 2 | 4 GiB | 3 | 6 | **17** |
| `t3.large` | 2 | 8 GiB | 3 | 12 | 35 |

Fórmula do VPC CNI: `ENIs × (IPv4 por ENI − 1) + 2`.

**3. O teto de réplicas está amarrado ao orçamento de conexões do banco**, declarado em
`service-track-db-infra` (`DB-ADR-004`). Aumentar `maxReplicas` sem rever o orçamento faz o
`terraform plan` do banco falhar. Não é um limite de opinião.

## Decisão

### HML: um `t3.small`, sem HPA, teto de 1 node

Um `t3.small` entrega 11 slots de pod. O que já ocupa esses slots antes da aplicação:

| Ocupante | Pods |
|---|---|
| `coredns` | 2 |
| `aws-node` (VPC CNI) | 1 |
| `kube-proxy` | 1 |
| `metrics-server` | 1 |
| Datadog node agent + cluster agent | 2 |
| **Subtotal** | **7** |

Sobram **4 slots** para a aplicação. É por isso que **HML não tem HPA**: copiar o teto de PRD
seria ficção — a partir da quinta réplica os pods ficariam `Pending` por falta de IP, não por
falta de CPU, e o sintoma (`0/1 nodes are available: too many pods`) não se parece nada com o
problema. Melhor não declarar autoscaling do que declarar um que não pode ser cumprido.

Memória confirma a escolha: 2 GiB brutos menos a reserva do kubelet dão cerca de 1,6 GiB
alocável. Com o limite de 512 MiB por pod da aplicação e 512 MiB do node agent do Datadog, 2
réplicas cabem com folga e 3 já apertam.

`node_max_size = 1`: HML nunca escala. A substituição de um node que morre continua garantida
pelo Auto Scaling Group, que mantém `desired_size = 1` — o teto acima de 1 só serviria para
escalar carga, que HML não faz.

### PRD: um `t3.medium`, HPA de 2 a 4, teto de 2 nodes

Um `t3.medium` entrega 17 slots. Descontando os mesmos 7 ocupantes de sistema, sobram **10
slots** para a aplicação — o dobro do que o HPA precisa no teto.

Aritmética de CPU com o HPA no máximo:

```
4 réplicas × 250m de request           = 1000m
Datadog node agent + cluster agent     =  200m
kube-system                            = ~400m
                                         ------
                                         1600m

1 × t3.medium alocável                 ≈ 1930m
```

**Tudo cabe em um único node.** Isso é escolha de demonstração, não acaso: o HPA escala de 2
para 4 sem precisar que o Cluster Autoscaler crie máquina, então a escala acontece em segundos
na frente de quem assiste. Com o dimensionamento anterior — 10 réplicas em 2 nodes — parte do
scale-out esperava um node novo subir, o que leva minutos e não cabe numa apresentação.

`node_max_size = 2` é a saída de emergência: dá ao Cluster Autoscaler para onde ir se algum
workload inesperado ocupar o node.

**`cluster_agent_replicas = 1` e `espalhar_por_az = false` são obrigatórios com um node.** O
módulo do Datadog aplica `podAntiAffinity` por zona quando `espalhar_por_az` está ligado, com
`requiredDuringSchedulingIgnoredDuringExecution`. Com dois réplicas e um node só, a segunda
ficaria `Pending` para sempre — e o `PodDisruptionBudget`, criado quando há mais de uma
réplica, passaria a bloquear drain do node.

### Por que `t3` e não `m5`/`c5`

As `t3` são burstable e têm o menor preço de entrada. O perfil de uso é o de um ambiente que
fica ligado por horas, não semanas, com carga concentrada em demonstração. `m5.large` custa
mais do que o dobro de `t3.medium` para entregar o dobro de memória que não é usada.

**Risco assumido:** instâncias `t3` acumulam créditos de CPU e, em modo `unlimited`, cobram
por vCPU excedente quando os créditos acabam. A baseline sustentada é 20% de 2 vCPU na
`t3.small` e 20% na `t3.medium`. Uma demonstração longa com carga sintética pode gerar custo
não previsto na tabela abaixo. Não é problema no uso real do projeto, mas é a razão de não se
usar este cluster para teste de carga prolongado.

## Custo

Referência us-east-1, sob demanda, valores aproximados. **Só valem enquanto o ambiente está
ligado** — o mês inteiro nunca acontece, por decisão ([ADR-014](ADR-014-estrategia-de-custo-conta-estudante.md)).

| Item | HML | PRD (mínimo) | PRD (teto) |
|---|---|---|---|
| Nodes | 1 × t3.small ≈ US$ 0,021/h | 1 × t3.medium ≈ US$ 0,042/h | 2 × t3.medium ≈ US$ 0,083/h |
| Equivalente mensal | ~US$ 15 | ~US$ 30 | ~US$ 60 |

O dimensionamento anterior (2 a 4 × `t3.large`) custava de US$ 120 a US$ 240 mensais
equivalentes. A revisão corta isso em **quatro vezes**.

Somado ao control plane (~US$ 73/mês por cluster), NAT (~US$ 32) e NLB (~US$ 16), **PRD ligado
o mês inteiro passa de US$ 150**. É o número que justifica a regra operacional de destruir o
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
- **PRD roda em um node só.** Perder esse node derruba a aplicação até o ASG substituir, o que
  leva alguns minutos. Aceito para um ambiente de apresentação; não seria aceitável em produção
  real.
- O teto de 4 réplicas exercita o HPA, mas não prova comportamento sob dezenas de réplicas.

### Impacto em ambiente efêmero

Nada aqui sobrevive a um `destroy`. Ao recriar, o node group nasce em `desired_size` e o
Cluster Autoscaler leva alguns minutos para reagir à primeira carga. Em apresentação, subir o
ambiente com antecedência e gerar tráfego antes de começar.

## Alternativas consideradas

**Mesmo tipo de instância nos dois ambientes.** Simplifica o Terraform e elimina a classe de
defeito "só acontece em PRD". Com a revisão de 02/08/2026 a diferença de custo caiu para
~US$ 15/mês, então o argumento financeiro quase desapareceu. Segue descartado por outro
motivo: HML em `t3.medium` teria 17 slots e passaria a comportar um HPA, e aí HML e PRD
deixariam de ter perfis distintos — some o ambiente barato que se destrói sem pensar.

**Fargate no lugar de node group.** Elimina o problema de slots de pod e o gerenciamento de
node. Descartado porque a `LabRole` do AWS Academy não permite criar os perfis de execução
que o Fargate exige, e porque o custo por pod/hora é maior para carga contínua.

**HPA em HML com `maxReplicas: 3`.** Caberia nos 4 slots. Descartado porque validaria um
comportamento de escala que não se parece com o de PRD, dando falsa confiança — pior do que
não ter.
