# ADR-009 — Uma API key por consumidor, com usage plan dedicado sob demanda

- **Status:** aceito
- **Data:** 2026-07-23

## Contexto

A implementação inicial criava **uma** API key por ambiente. Consequências:

- revogar a chave derrubava todos os clientes de uma vez;
- as métricas de uso do usage plan agregavam front web, mobile e pipeline num
  número só, impossibilitando saber quem consumiu a quota;
- não havia como aplicar limite diferente a um consumidor específico.

## Decisão

Os consumidores passam a ser declarados no EXT, em
`api-configuration/usage-plan/config-<ENV>.yaml`, e cada um ganha sua própria API
key:

```yaml
consumers:
  web:
    description: Front-end web
    enabled: true
  mobile:
    description: Aplicativo mobile
    enabled: true
  ci:
    description: Contract test da pipeline
    enabled: true
    throttle: { rateLimit: 5, burstLimit: 10 }
    quota:    { limit: 1000, period: DAY }
```

Regra: **consumidor sem `throttle`/`quota` compartilha o usage plan do ambiente;
consumidor que declara qualquer um dos dois ganha um usage plan dedicado**, com
os campos não informados herdando o plano padrão.

## Justificativa

### Por que não um usage plan por consumidor sempre

Seria mais uniforme, mas cria N usage plans onde um bastaria, e a maioria dos
consumidores tem exatamente os mesmos limites. O critério "declarou limite → tem
plano próprio" mantém o caso comum trivial e o caso especial possível, sem flag
extra: a presença da configuração **é** a decisão.

### Por que ficou no arquivo de usage plan e não num diretório novo

O ADR-004 fixou que agrupamentos só existem quando há conteúdo real. Consumidor e
limite de consumo são o mesmo assunto — quem chama e quanto pode chamar. Um
diretório `consumers/` com um mapa de três linhas seria estrutura sem substância.

### Por que `enabled` em vez de remover a entrada

Remover o consumidor do YAML destrói a key. `enabled: false` desliga o
consumidor mantendo a intenção documentada e revisável no diff. Também torna a
revogação um one-liner.

### O consumidor `ci`

Existe para o contract test da pipeline
([ADR-010](ADR-010-contract-testing-na-pipeline.md)). Em PRD ele tem limites
dedicados **propositalmente baixos** (5 req/s, 1.000/dia): a pipeline faz
dezenas de chamadas, não milhares, e um teste em loop não deve conseguir consumir
a quota de produção dos clientes reais.

## Consequências

- O output mudou de `api_key_value` (string) para **`api_key_values`** (mapa,
  sensível). Consumo:

  ```bash
  terraform output -json api_key_values | jq -r .web
  ```

  `terraform output -raw` não funciona em mapa. Docs e pipeline foram ajustados.
- Novo output `api_consumers` lista quem está habilitado, sem expor segredo.
- Revogar um consumidor é `enabled: false` + `apply`; os demais não são afetados.
- Métricas do usage plan passam a ser por consumidor.
- HML e PRD precisam declarar **o mesmo conjunto de nomes** de consumidores — os
  limites podem divergir, os nomes não. A pipeline verifica isso; divergência
  quebra o job de contrato.
