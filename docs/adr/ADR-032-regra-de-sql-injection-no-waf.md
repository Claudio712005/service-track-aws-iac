# IAC-ADR-032: regra gerenciada de SQL injection no WAF

## Data
03/10/2026

## Status
Aceita.

---

## Contexto

O WAF da borda tinha **uma** regra: limite por IP, com bloqueio acima de 2000 requisições na janela.
Isso cobre inundação, não conteúdo. Faltava regra de conteúdo contra tentativa de injeção de SQL —
exigência comum de avaliação de segurança e item que a banca cobra na apresentação.

Vale registrar o que o levantamento no código mostrou, porque muda o peso desta decisão: **não há
concatenação de SQL em nenhum dos serviços.** O único SQL nativo do projeto usa parâmetro nomeado:

```kotlin
@Query(
    value = "SELECT * FROM CATALOGO.OUTBOX WHERE DATA_PUBLICACAO IS NULL " +
        "ORDER BY DATA_CRIACAO LIMIT :maximo FOR UPDATE SKIP LOCKED",
    nativeQuery = true,
)
```

Todo o resto é consulta derivada do Spring Data, Criteria API ou driver do Mongo. A superfície real de
injeção, hoje, é nula.

## Decisão

Acrescentar ao WebACL a regra gerenciada **`AWSManagedRulesSQLiRuleSet`** da AWS, em prioridade 2,
depois do limite por IP.

A configuração é por ambiente, no mesmo arquivo onde o plano de uso e o limite já vivem:

```yaml
waf:
  enabled: true
  rateLimit: 2000
  sqlInjection:
    enabled: true
    mode: block      # block | count
```

- `mode: block` aplica a ação do grupo gerenciado, que é bloquear.
- `mode: count` apenas conta e marca a requisição, sem bloquear. Serve para medir falso positivo
  antes de ligar o bloqueio num ambiente onde isso importa.
- Ausência da chave `sqlInjection` equivale a habilitada em `block`, para que configuração antiga
  continue válida.

**O WAF passa a ser habilitado em HML também.** O `IAC-ADR-014` o havia cortado de HML por custo, com
a conta de um ambiente ligado o mês inteiro. O ambiente é usado duas a três horas por dia e destruído
depois: o WebACL custa US$ 5 por mês rateado por hora, e o grupo gerenciado US$ 1 — em noventa horas
por mês, **menos de um dólar**. Regra de segurança que só existe em produção não é testada, e a
primeira vez que ela bloqueia algo legítimo não pode ser durante a apresentação.

## Consequências

- Tentativa de injeção em caminho, parâmetro de consulta, cabeçalho ou corpo passa a ser bloqueada na
  borda, com métrica no CloudWatch e amostra da requisição — o que serve como evidência na
  apresentação.
- **Isto é defesa em profundidade, não o controle principal.** O controle principal é consulta
  parametrizada, que já existe. Uma regra de WAF protege contra o que ainda não foi escrito, e contra
  caminho que ninguém revisou.
- **O WAF só vê o que passa pelo gateway.** Os microsserviços são `Service type=ClusterIP` em subnet
  privada, sem integração no gateway: hoje nada deles passa por aqui. Quando o BFF for exposto, ele
  passa — e os serviços continuam atrás dele, dentro do cluster. Ligar esta regra **não** protege
  chamada feita de dentro do cluster, e não deve dar essa impressão.
- Falso positivo é possível: o grupo gerenciado inspeciona corpo, e texto legítimo com aspa simples ou
  dois hifens pode casar. Nossos corpos atuais são nome, descrição e número, e a coleção do Postman não
  tem esse conteúdo — mas o `mode: count` existe para o dia em que tiver.
- Custo total do WAF em HML, com uso de três horas por dia: cerca de **US$ 0,74 por mês**, mais
  US$ 0,60 por milhão de requisições.
- O limite de capacidade do WebACL não é problema: o grupo gerenciado de SQLi consome 200 WCU do teto
  padrão de 1500.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Regra própria com `sqli_match_statement` por campo | reinventa um conjunto que a AWS mantém e atualiza, e cobre menos campos do que o grupo gerenciado |
| `AWSManagedRulesCommonRuleSet` inteiro | traz dezenas de regras além de injeção, com falso positivo bem mais provável, para um ganho que ninguém pediu |
| Deixar só em PRD, como estava | regra de segurança não exercitada em HML é regra que se descobre quebrada na apresentação |
| Confiar apenas na consulta parametrizada | é o controle principal e continua sendo, mas não cobre código futuro nem caminho não revisado |
| WAF em modo `count` em toda parte | não protege; serve para medir, e não há falso positivo conhecido a medir hoje |
