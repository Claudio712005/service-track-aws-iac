# ADR-006 — Ambientes efêmeros e restrições da conta AWS educacional

- **Status:** aceito
- **Data:** 2026-07-23

## Contexto

A infraestrutura roda em conta AWS Educate/Student. Características que
condicionam o desenho:

- Todas as roles são a **`LabRole`** existente (`data "aws_iam_role" "lab"`). Não
  se criam roles nem policies.
- As credenciais expiram a cada sessão de laboratório.
- Ambientes são destruídos e recriados com frequência.
- Free tier e orçamento reduzido.

O requisito é: `terraform destroy` seguido de `terraform apply` reconstrói a API
inteira, sem nenhum passo manual no console.

## Decisões

### 1. Nada de configuração manual no API Gateway

Tudo que o console permitiria configurar à mão está em código:

| Item | Onde está definido |
|---|---|
| Rotas, métodos, schemas, validação | `openApi.yaml` → `aws_api_gateway_rest_api.body` |
| Stage | `aws_api_gateway_stage` (nome = ambiente) |
| Deployment | `aws_api_gateway_deployment`, trigger `sha1(body)` |
| Usage Plan e quota | `aws_api_gateway_usage_plan` ← `usage-plan/config-<ENV>.yaml` |
| API Key e vínculo com o plano | `aws_api_gateway_api_key` + `aws_api_gateway_usage_plan_key` |
| CORS (preflight e erros) | mock OPTIONS + `aws_api_gateway_gateway_response` ← `cors/config-<ENV>.yaml` |
| Integração com backends | `x-amazon-apigateway-integration` no contrato |
| VPC Link e NLB | `iac/modules/vpc-link` |
| Permissão de invocação da Lambda | `aws_lambda_permission` |

Não há `terraform import`, não há recurso criado fora do state.

### 2. Isolamento entre HML e PRD

Mantido o padrão que já existia no repositório, sem alterações estruturais:

- State separado por ambiente no S3: `servicetrack/hml/terraform.tfstate` e
  `servicetrack/prd/terraform.tfstate`.
- Cada ambiente é um root module fino que chama `modules/stack` com o seu sizing.
- VPCs distintas: `10.10.0.0/16` (hml) e `10.20.0.0/16` (prd).
- Recursos nomeados por `${project}-${environment}`, então não há colisão de nome
  na conta.
- Stage do API Gateway = nome do ambiente, e cada ambiente tem seu próprio REST
  API, usage plan e API key.
- Configuração de exposição por ambiente em arquivos separados
  (`config-HML.yaml` / `config-PRD.yaml`), não por condicional em HCL.

Destruir HML não toca em nada de PRD.

### 3. API Key é regenerada, não versionada

`aws_api_gateway_api_key` gera um valor novo a cada criação. O valor **não** é
fixado no código — fixar exigiria versionar um segredo.

Consequência aceita: **após cada recriação, os clientes precisam da chave nova**:

```bash
terraform output -raw api_key_value
```

Para um ambiente efêmero e acadêmico isso é adequado. Uma chave estável exigiria
Secrets Manager (custo por segredo) ou valor versionado (inseguro).

### 4. Access logs: o caso do recurso global

Access log e execution log do API Gateway REST dependem de uma role de CloudWatch
configurada no **nível da conta** (`aws_api_gateway_account`) — um recurso
*singleton* por conta/região, enquanto temos dois states.

Análise do risco: HML e PRD apontam para a **mesma `LabRole`**, então ambos
escrevem o mesmo valor e não há divergência. E no provider AWS 5.x (`~> 5.60`,
travado em `versions.tf`) o *delete* de `aws_api_gateway_account` **não reseta a
configuração da conta** — apenas remove o recurso do state. Portanto destruir HML
não desliga o log de PRD.

Decisão: gerenciar o recurso nos dois ambientes, com `enable_api_access_logs`
(default `true`) como escape.

**Risco residual:** a `LabRole` precisa ser assumível por
`apigateway.amazonaws.com`. Se a trust policy da conta não permitir, o apply falha
nesse recurso. Correção sem alterar código:

```bash
terraform apply -var="enable_api_access_logs=false"
```

Com logs desligados, `logging_level` vai para `OFF` e `data_trace_enabled` para
`false` automaticamente — a API continua funcional, só sem log.

### 5. Contenção de custo

| Escolha | Alternativa evitada | Razão |
|---|---|---|
| Sem WAF | WAF para rate limiting | custo fixo mensal; usage plan resolve |
| Sem cache de stage | cache do API Gateway | cobrado por hora, por GB |
| Sem X-Ray | tracing distribuído | custo por trace |
| `detailedMetrics: false` em PRD | métrica por método | cobrada por métrica; a API tem 49 operações |
| Sem domínio customizado | Route53 + ACM | zona hospedada tem custo mensal e o domínio não existe |
| Retenção de log 7d (hml) / 14d (prd) | retenção indefinida | CloudWatch cobra por GB armazenado |
| Sem Secrets Manager para a API key | segredo gerenciado | cobrado por segredo/mês |

O NLB (~US$ 16/mês se ligado continuamente) é o único componente pago relevante
adicionado, e é inevitável para integração privada com o EKS
(ver [ADR-003](ADR-003-integracao-backend-eks-vpc-link.md)). Em uso efêmero, custa
centavos.

## Consequências

- O ciclo destroy/apply é íntegro, mas **lento**: o VPC Link leva de 5 a 10
  minutos para criar e o mesmo para destruir.
- O `scripts/aws-lb-cleanup.sh` continua necessário antes do destroy, por causa
  dos LoadBalancers criados pelo Kubernetes (ArgoCD). O NLB do VPC Link é do
  Terraform e sai no destroy normal.
- A URL da API e a API key mudam a cada recriação. Qualquer front-end precisa
  lê-las dos outputs, não de constante compilada.
