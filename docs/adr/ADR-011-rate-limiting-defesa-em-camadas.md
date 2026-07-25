# ADR-011 — Rate limiting e defesa em camadas na borda

- **Status:** aceito
- **Data:** 2026-07-24

## Contexto

A API é exposta publicamente pelo API Gateway. Sem limite de taxa, um cliente
(malicioso ou com bug) consegue esgotar o backend, a Lambda de autenticação ou o
free tier da conta educacional. O rate limiting precisa ser **definido no
gateway** — não no backend — para barrar o excesso antes de gastar recurso, e
precisa **variar por ambiente** (PRD aguenta mais que HML).

## Decisão

Defesa em camadas, todas na borda, aplicadas em ordem por cada requisição:

```
                          requisição
                              │
                              ▼
   1. WAF rate-based (por IP) ......... só PRD ....... 429/403 se flood por IP
                              │
                              ▼
   2. API key + usage plan (por key) .. todos env .... 403 sem key / 429 acima
                              │
                              ▼
   3. Throttle do stage (global) ...... todos env .... 429 acima do teto da API
                              │
                              ▼
   4. Request validation .............. todos env .... 400 se contrato violado
                              │
                              ▼
   5. Authorizer JWT (opcional) ....... ADR-007 ...... 401 se token invalido
                              │
                              ▼
                           backend
```

Cada camada mira um vetor diferente:

| Camada | Chave de agregação | Defende contra |
|---|---|---|
| WAF rate-based | **IP de origem** | flood anônimo/distribuído, scraping |
| Usage plan | **API key** | consumidor específico abusando |
| Stage throttle | **API inteira** | rede de segurança global |

Usage plan é por API key: não protege contra quem não tem key (o 403 é barato,
mas um flood de 403 ainda consome capacidade do gateway). O WAF fecha essa
lacuna barrando por IP antes da avaliação da key.

## Valores por ambiente

Definidos em `apis/service-track-api-ext/api-configuration/usage-plan/config-<ENV>.yaml`.

| Controle | Recurso AWS | Escopo | HML | PRD |
|---|---|---|---|---|
| Rate por key | `aws_api_gateway_usage_plan.throttle` | por API key | 20 req/s | 100 req/s |
| Burst por key | idem | por API key | 40 | 200 |
| Quota | `aws_api_gateway_usage_plan.quota` | por API key | 10.000/dia | 200.000/mês |
| Rate do stage | `aws_api_gateway_method_settings` | API inteira | 50 req/s | 200 req/s |
| Burst do stage | idem | API inteira | 100 | 400 |
| WAF rate-based | `aws_wafv2_web_acl` | por IP / 5 min | **desligado** | 2.000 |

### Rate vs. burst (o que cada um significa)

O API Gateway usa **token bucket**. `rate` é a taxa sustentada de reposição de
tokens (req/s em regime permanente); `burst` é o tamanho do balde — quantas
requisições podem chegar num pico instantâneo antes do rate voltar a valer.
Burst sempre ≥ rate; aqui é 2× o rate em todos os níveis, absorvendo rajadas
curtas de cliente legítimo sem liberar abuso sustentado.

### Por que WAF só em PRD

O WAFv2 custa ~US$ 5/mês por Web ACL + ~US$ 1/regra, cobrado mesmo sem tráfego.
HML foi enxugado para liberar orçamento para observabilidade
([ADR-006](ADR-006-ambientes-efemeros-e-conta-educacional.md)), e um ambiente de
teste não recebe flood real. Em HML a defesa fica no throttle do usage plan, que
não tem custo adicional. O `waf.enabled` no config de HML é `false`; o bloco
existe nos dois arquivos com o mesmo shape para manter a checagem de consistência
da pipeline verde.

### A regra do WAF

Uma única regra `rate_based_statement` agregando por `IP`, ação `block`: um IP
que ultrapassa 2.000 requisições em qualquer janela de 5 minutos é bloqueado até
cair abaixo do limite. `default_action` é `allow` — o WAF não filtra conteúdo,
só limita taxa. Métricas e requisições amostradas vão para o CloudWatch.

O valor 2.000/5min ≈ 6,7 req/s por IP é folgado para um cliente legítimo (o front
faz poucas chamadas por usuário) e ainda assim corta scraping e flood de um IP.

## Consequências

- Rate limiting é **configuração versionada por ambiente**, não código: mudar um
  limite é editar o YAML e `terraform apply`.
- O WAF adiciona custo fixo em PRD (~US$ 6/mês). Aceito por ser o ambiente
  exposto de verdade.
- Um bloqueio do WAF (429) e um estouro de throttle (429) são cobertos pelo
  `gateway_response` de `DEFAULT_4XX`, então carregam headers de CORS
  ([ADR-004](ADR-004-fronteira-ext-terraform.md)).
- O WAF é por IP: clientes atrás de um NAT compartilhado somam no mesmo balde.
  Para a escala atual não é problema; se virar, migra-se a agregação para
  `FORWARDED_IP` com `X-Forwarded-For` confiável.
- A quota é o único limite que não se recupera sozinho na janela: estourá-la
  bloqueia a key até o fim do período (dia/mês).

## Evolução possível

- Regras gerenciadas da AWS (`AWSManagedRulesCommonRuleSet`) no mesmo Web ACL,
  para cobrir OWASP Top 10 além de rate limiting.
- Rate-based com `scope-down statement` para limites diferentes por rota (ex.:
  `/autenticacao` mais restrito que leitura de catálogo).
- Bloqueio geográfico se o público for só nacional.
