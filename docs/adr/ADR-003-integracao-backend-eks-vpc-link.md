# ADR-003 — Integração com o backend: Lambda por rota e EKS via VPC Link + NLB

- **Status:** aceito
- **Data:** 2026-07-23

## Contexto

A Service Track API tem **dois backends** na infraestrutura existente:

- **Lambda** (`modules/lambda`, imagem Quarkus/Kotlin do repositório
  [service-track-lambda](https://github.com/Claudio712005/service-track-lambda)) —
  serviço de autenticação.
- **Aplicação no EKS** (`modules/eks`, imagem do ECR `servicetrack-app`,
  entregue por ArgoCD) — todo o resto do domínio: clientes, veículos, serviços,
  insumos, ordens de serviço, notificações, dashboard.

O módulo `api-gateway` anterior mandava **tudo** (`ANY /{proxy+}`) para a Lambda.
Isso funcionava só porque nada além de `/autenticacao` era chamado pelo gateway;
a aplicação no EKS não estava exposta por ele.

Não existe AWS Load Balancer Controller no cluster. O único LoadBalancer criado
hoje vem do `Service type=LoadBalancer` do ArgoCD.

## Decisão

Rotear por rota, com dois tipos de integração:

| Rotas | Integração | Backend |
|---|---|---|
| `POST /autenticacao`, `POST /autenticacao/reset-senha` | `aws_proxy` | Lambda de autenticação |
| Todas as demais (47 operações) | `http_proxy` + `connectionType: VPC_LINK` | Aplicação no EKS |

O caminho até o EKS é: **API Gateway → VPC Link → NLB interno → NodePort → Service**.

O NLB é criado pelo **Terraform** (`iac/modules/vpc-link`), não pelo Kubernetes.

## Justificativa

### Por que o NLB é do Terraform e não um `Service type=LoadBalancer`

O `aws_api_gateway_vpc_link` precisa do **ARN do load balancer em tempo de apply**.
Se o NLB fosse criado por um Service do Kubernetes, ele só existiria depois de o
ArgoCD sincronizar a aplicação — ou seja, depois do `terraform apply`. O Terraform
não teria como referenciá-lo sem um `data source` que falharia no primeiro apply.
Isso quebraria o princípio de reprodutibilidade ("um `terraform apply` reconstrói
tudo").

Criando o NLB no Terraform, a ordem fica determinística e o `apply` é auto-contido.

### Por que NLB e não ALB

O VPC Link do API Gateway REST (v1) **só aceita Network Load Balancer**. Não é uma
escolha: é a única opção compatível.

### Por que `instance` targets ligados ao ASG

O target group registra o **Auto Scaling Group do node group**
(`aws_autoscaling_attachment`), não instâncias individuais. Nodes que entram ou
saem por autoscaling são registrados e removidos automaticamente, sem apply.

### Por que integração privada e não um ALB público

Um ALB público na frente do EKS permitiria contornar o API Gateway, tornando o
API Key, o throttling e a quota decorativos. Com NLB **interno** em subnet
privada, o único caminho de entrada é o gateway.

## Contrato com os manifestos do Kubernetes

Este é o único acoplamento entre este repositório e o repositório de manifestos:

> O `Service` da aplicação precisa ser `type: NodePort` com
> `nodePort: 30080` (valor de `var.app_node_port`).

Se esse contrato for quebrado, o target group fica *unhealthy* e o gateway
responde 503 — a infraestrutura sobe normalmente. O valor é parametrizado em
`modules/stack/variables.tf`, então mudar é alterar uma variável, não código.

## Divisão das rotas de autenticação

Somente `/autenticacao` e `/autenticacao/reset-senha` vão para a Lambda.
`POST /clientes` e `POST /mecanicos` (cadastro público) vão para o EKS, porque
são operações de domínio, não de emissão de token.

**Este é o ponto do desenho com menos evidência no repositório.** A divisão foi
inferida do nome do serviço ("auth") e do README. Se o cadastro também estiver na
Lambda, a correção é trocar o bloco `x-amazon-apigateway-integration` das duas
rotas no `openApi.yaml` — nenhuma mudança em Terraform é necessária.

## Consequências

- **Custo:** um NLB por ambiente, ~US$ 16/mês se ficar ligado o mês inteiro. Como
  os ambientes são efêmeros e destruídos após uso, na prática são centavos.
- `terraform apply` fica mais lento: criar um VPC Link leva de 5 a 10 minutos, e
  destruir também. É o recurso mais lento do stack.
- O health check do target group é **TCP** por padrão
  (`var.app_health_check_protocol`), não HTTP. TCP não depende de a aplicação
  expor uma rota de health específica, que varia entre Spring (`/actuator/health`)
  e Quarkus (`/q/health`). Trocar para HTTP é mudar duas variáveis.
- Foi adicionada uma regra de ingress no security group dos nodes liberando o
  NodePort para o CIDR da VPC. Sem ela o health check nunca fica *healthy*.
