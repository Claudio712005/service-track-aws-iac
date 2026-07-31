# RFC-006 — Dimensionamento de compute por ambiente

- **Status:** implementado
- **Data:** 2026-07-31
- **ADR resultante:** [023](../adr/ADR-023-dimensionamento-de-compute-por-ambiente.md)

## 1. Problema

HML e PRD rodam o mesmo artefato, mas os node groups são diferentes: `t3.small` com 1 node
contra `t3.large` com 2 a 4. A diferença estava no Terraform sem justificativa escrita, o que
gera duas perguntas recorrentes e sem resposta registrada:

1. Por que HML não tem HPA, se o requisito da fase pede autoscaling?
2. Por que `t3.large` em PRD, se `t3.large` tem a mesma quantidade de vCPU que `t3.small`?

Sem resposta escrita, a tendência é "arredondar para cima" no próximo ajuste — que é
exatamente o que a conta AWS Academy não suporta.

## 2. Restrições que limitam o espaço de solução

**Orçamento.** Conta educacional, crédito finito, ambientes destruídos após cada uso. O que
importa é custo por hora ligada.

**Slots de pod.** O VPC CNI dá um IP de subnet por pod. `t3.small` = 11 pods; `t3.large` = 35.
É o limite que morde primeiro, antes de CPU e memória.

**Orçamento de conexões do banco.** `DB-ADR-004` amarra `maxReplicas` ao teto de conexões do
RDS. O `terraform plan` do banco falha se a soma estourar. O teto de 10 réplicas não é
negociável no Terraform do cluster.

**`LabRole`.** Sem criação de role, o que elimina Fargate e IRSA.

## 3. Opções avaliadas

### A. Mesma instância nos dois ambientes

`t3.large` em HML e PRD. Elimina a classe de defeito "só aparece em PRD" e simplifica o
Terraform.

Custo: HML sairia de ~US$ 15 para ~US$ 60/mês equivalente. Em um ambiente cuja razão de existir
é ser descartável e barato, o ganho de fidelidade não paga.

**Rejeitada por custo.**

### B. `t3.medium` em PRD

17 slots por node. Com 2 nodes, 34 slots — suficiente para 10 réplicas mais o sistema.
Custo ~US$ 30/mês por node contra ~US$ 60 de `t3.large`.

Foi a opção mais disputada. Perdeu pela margem de memória: com 4 GiB e ~3,2 GiB alocáveis, 10
réplicas a 512 MiB de limite mais o node agent do Datadog encostam no teto do node, e o
comportamento sob pressão de memória (OOMKill do pod errado) é o tipo de falha que aparece na
apresentação.

**Rejeitada por margem, com ressalva:** se o limite de memória do pod cair para 384 MiB,
`t3.medium` volta a ser a escolha certa e economiza ~US$ 60/mês em PRD.

### C. HPA em HML com teto reduzido

`maxReplicas: 3`, cabendo nos 4 slots livres do `t3.small`.

Rejeitada por dar falsa confiança: validaria um comportamento de escala que não se parece com o
de PRD. Um HPA que nunca chega a escalar de verdade é pior que nenhum, porque quem lê o
manifesto assume que o caminho está exercitado.

### D. Fargate

Elimina slots de pod e gerenciamento de node. Bloqueada pela `LabRole`: o Fargate exige perfil
de execução próprio, que a conta não permite criar.

**Rejeitada por impossibilidade técnica.**

## 4. Solução adotada

`t3.small` × 1 (teto 2) em HML, sem HPA. `t3.large` × 2 (teto 4) em PRD, HPA de 2 a 10.

A aritmética que sustenta cada número está em
[ADR-023](../adr/ADR-023-dimensionamento-de-compute-por-ambiente.md).

## 5. Riscos conhecidos

| Risco | Mitigação |
|---|---|
| HML não exercita autoscaling; defeito de concorrência entre réplicas passa direto | Aceito e documentado. Teste de múltiplas réplicas é manual, em PRD, antes da apresentação |
| Créditos de CPU da família `t3` esgotam em carga sustentada e geram custo não previsto | Não usar este cluster para teste de carga prolongado |
| `node_max_size = 4` em PRD com 10 réplicas deixa pouca folga de CPU | Cluster Autoscaler tem espaço para 2 nodes extras antes do teto |

## 6. Evolução possível

- Reduzir o limite de memória do pod para 384 MiB e reavaliar `t3.medium` em PRD (~US$ 60/mês).
- Instâncias Spot no node group de HML: até 70% de desconto, e a interrupção é irrelevante em
  ambiente de teste.
- Rever o teto do HPA junto com o orçamento de conexões: hoje 10 réplicas × 15 conexões
  consomem 170 das 300 do `db.t3.medium`.
