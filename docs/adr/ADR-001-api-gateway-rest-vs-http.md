# ADR-001 — API Gateway REST (v1) em vez de HTTP (v2)

- **Status:** aceito
- **Data:** 2026-07-23
- **Contexto:** exposição externa (EXT) da Service Track API

## Contexto

O repositório já tinha um módulo `iac/modules/api-gateway` usando **HTTP API (v2)**
com uma única rota `ANY /{proxy+}` apontando para a Lambda de autenticação. Aquele
módulo resolvia um problema menor: publicar a Lambda. Ele não resolvia o problema
do EXT, que é expor a API inteira com contrato, controle de consumo e validação.

A configuração pré-existente em `apis/service-track-api-ext/api-configuration/`
já declarava explicitamente `usagePlanConfigFile` e `corsConfigFile`, ou seja, o
Usage Plan sempre foi um requisito do EXT.

## Decisão

Usar **API Gateway REST API (v1)**.

## Justificativa

O fator decisivo é capacidade, não preferência. Recursos exigidos pelo EXT que o
HTTP API **não possui**:

| Requisito do EXT | REST (v1) | HTTP (v2) |
|---|---|---|
| Usage Plans | sim | **não existe** |
| API Keys | sim | **não existe** |
| Quota (limite diário/mensal) | sim | **não existe** |
| Request validation por JSON Schema | sim | **não existe** |
| Import de OpenAPI com integração por rota | completo | parcial |
| VPC Link para NLB | sim | só ALB/NLB via VPC Link v2 |
| Throttling por stage e por método | sim | só por rota |

Sem Usage Plan e API Key não há como cumprir os itens "Usage Plans", "API Keys",
"throttling" e "quotas" do escopo do EXT. Isso elimina o HTTP API.

## Consequências

- **Custo:** REST custa US$ 3,50/milhão de requisições contra US$ 1,00/milhão do
  HTTP. No volume deste projeto (acadêmico, ambientes efêmeros) a diferença é
  irrelevante e cabe no free tier de 1 milhão de requisições/mês do primeiro ano.
- O módulo `api-gateway` foi **reescrito**, não estendido. Os recursos
  `aws_apigatewayv2_*` foram substituídos por `aws_api_gateway_*`.
- A URL pública muda de formato: agora inclui o stage
  (`https://{id}.execute-api.us-east-1.amazonaws.com/hml`), porque o REST API não
  tem equivalente ao stage `$default` do HTTP API.
- O roteamento deixou de ser `ANY /{proxy+}`: cada rota do contrato vira um
  resource/method real no gateway. Isso é o que habilita validação de request e
  roteamento para backends diferentes por rota (ver [ADR-003](ADR-003-integracao-backend-eks-vpc-link.md)).

## Alternativas consideradas

- **Manter HTTP API e implementar throttling no backend.** Rejeitado: joga para a
  aplicação uma responsabilidade que o EXT deve resolver na borda, e não entrega
  API Key nem quota.
- **HTTP API + WAF para rate limiting.** Rejeitado: WAF tem custo fixo mensal
  relevante para conta educacional e não entrega quota por consumidor.
