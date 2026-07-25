# ADR-014 — Estratégia de custo na conta de estudante

- **Status:** aceito
- **Data:** 2026-07-24

## Contexto

A infraestrutura roda em conta AWS Academy, com orçamento limitado e crédito que
pode ser esgotado. O time **não deixa a AWS ligada a semana inteira** — os
ambientes são criados para testes/apresentações e destruídos em seguida. As
decisões de custo partem dessa premissa, não de um ambiente 24×7.

## Custos fixos relevantes

Por ambiente, com tudo ligado:

| Item | Custo aproximado | Observação |
|---|---|---|
| Control plane EKS | ~US$ 73/mês | por cluster, cobrado enquanto existir |
| NAT Gateway | ~US$ 32/mês | + tráfego processado |
| NLB (VPC Link) | ~US$ 16/mês | inevitável para integração privada com o EKS |
| WAF (só PRD) | ~US$ 6/mês | ver [ADR-011](ADR-011-rate-limiting-defesa-em-camadas.md) |
| Route53 hosted zone | ~US$ 0,50/mês | persistente, ver [ADR-008](ADR-008-dominio-customizado-opcional.md) |

Dois ambientes simultâneos ligados = ~US$ 250+/mês, acima do teto típico da
Academy. O controle central de custo **não é técnico, é operacional**: destruir o
que não está em uso.

## Decisões

### 1. A principal alavanca é destruir quando ocioso

O ciclo `terraform destroy` / `terraform apply` reconstrói o ambiente inteiro
sem passo manual ([ADR-006](ADR-006-ambientes-efemeros-e-conta-educacional.md)).
Não se mantém HML e PRD ligados juntos por conveniência; sobe-se o necessário
para a tarefa e destrói-se depois. O custo por hora ligada é o que importa, não o
mensal.

### 2. Cortes estruturais já aplicados

| Corte | Onde | Economia |
|---|---|---|
| HML sem LoadBalancer do ArgoCD | `argocd_expose_lb=false` | ~US$ 16/mês |
| HML sem métricas detalhadas do API Gateway | `detailedMetrics=false` | até ~US$ 100/mês |
| WAF só em PRD | `waf.enabled` por ambiente | ~US$ 6/mês em HML |
| HML sem domínio customizado | sem `custom_domain` em HML | ACM/alias evitados |
| Retenção de logs curta | 3 dias (HML) / 14 (PRD) | armazenamento CloudWatch |
| Sem LoadBalancer público na app | NodePort + VPC Link | ~US$ 16/mês, ver [ADR-012](ADR-012-gitops-eks-nodeport.md) |

### 3. ECR: retenção e imagens por ambiente

Repositórios ECR passam a ser **por ambiente** (`servicetrack-hml-app`,
`servicetrack-prd-app`) e cada um tem **lifecycle policy**: mantém as últimas 10
imagens tagueadas e expira as sem tag após 7 dias. Evita acúmulo de camadas
pagas e mantém uma média saudável de imagens por ambiente. Ver
[ADR-015](ADR-015-cd-imagem-por-ambiente.md).

### 4. VPC endpoint S3 (gateway) — custo zero

Adicionado um **gateway endpoint de S3** na route table privada. O download das
camadas de imagem do ECR (que ficam em S3) passa a não atravessar o NAT Gateway,
reduzindo o tráfego processado (que é cobrado). Gateway endpoints não têm custo
fixo nem por hora — é economia sem contrapartida.

Endpoints de interface para ECR (`ecr.api`, `ecr.dkr`) foram **descartados**:
custam ~US$ 7/mês cada, e num ambiente que fica ligado poucas horas o ganho de
tráfego não compensa o custo fixo.

### 5. O que NÃO foi feito e por quê

- **NAT instance no lugar de NAT Gateway** (~US$ 4 vs ~US$ 32): economiza, mas
  adiciona um ponto de falha gerenciado à mão. Num ambiente que fica ligado
  poucas horas, o NAT Gateway custa centavos por sessão — não vale a fragilidade.
- **Cluster único com namespace por ambiente**: economizaria um control plane,
  mas acopla HML e PRD (blast radius, versionamento). Mantidos separados; o
  controle de custo é destruir o ocioso, não fundir.

## Consequências

- O custo real é função de **horas ligadas**, então disciplina operacional
  (destruir após uso) vale mais que qualquer otimização de recurso.
- HML é deliberadamente mais barato que PRD; ver a tabela de diferenças no
  README.
- O S3 endpoint e a lifecycle policy são ganhos permanentes, sem contrapartida.
- Persistência entre sessões (state, zona, ECR) não é tratada como problema: a
  conta não é zerada no uso normal, e os ambientes são recriáveis por
  `terraform apply`.
