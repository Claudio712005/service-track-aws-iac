# ADR-025 — Regras de security group e a fronteira entre states

- **Status:** aceito
- **Data:** 2026-07-31
- **Origem:** [RFC-008](../rfc/RFC-008-regras-de-security-group.md)

## Contexto

Security group é a única fronteira de rede que o projeto realmente aplica: não há NACL
customizada, não há Network Policy no cluster e o NLB não filtra. Quatro security groups
importam, e um deles nasce em **outro repositório**.

O que este ADR resolve: por que uma das regras usa CIDR em vez de referência a security group,
por que o SG do banco não tem regra de entrada declarada onde é criado, e por que os egress
são abertos.

## Decisão

### 1. Matriz completa

| # | SG de destino | Porta | Origem | Repositório que declara |
|---|---|---|---|---|
| 1 | `<name>-app-nlb-sg` | 80/tcp | **CIDR da VPC** | `aws-iac`, módulo `vpc-link` |
| 2 | SG do node group | 30080/tcp | SG do NLB | `aws-iac`, módulo `vpc-link` |
| 3 | SG do RDS | 5432/tcp | SG do cluster EKS | `aws-iac`, módulo `stack` |
| 4 | SG do RDS | 5432/tcp | SG da Lambda | `aws-iac`, módulo `stack` |

Egress:

| SG | Egress | Justificativa |
|---|---|---|
| NLB | 30080/tcp apenas para o SG do node | única regra de saída estreita do conjunto |
| Lambda | `0.0.0.0/0`, todos os protocolos | precisa de RDS, Secrets/SSM e resolução DNS |
| RDS | `0.0.0.0/0`, todos os protocolos | herdado do módulo; o banco não inicia conexão |
| Node group | gerenciado pelo EKS | ECR, S3, API do cluster, integrações externas |

### 2. A regra 1 usa CIDR porque não existe alternativa

A entrada do NLB é `80/tcp` a partir de `var.vpc_cidr` — `10.10.0.0/16` ou `10.20.0.0/16`, a
VPC inteira. É a regra mais larga do sistema e não é descuido:

> As ENIs que o **VPC Link** cria não são referenciáveis por security group. A AWS não expõe um
> security group para elas, então não há como escrever `source_security_group_id`.

As opções eram CIDR da VPC ou os CIDRs das subnets privadas. A segunda é mais estreita, mas
quebra quando se acrescenta uma AZ e ninguém lembra de atualizar a lista. Ficou o CIDR da VPC,
com o comentário explicando o porquê no próprio recurso.

**O que isso significa na prática:** qualquer coisa dentro da VPC pode falar com o NLB na porta
80. Como o NLB é `internal` e só encaminha para o NodePort, o alcance real é "quem já está
dentro da VPC pode chamar a aplicação sem passar pelo API Gateway".

**Essa é exatamente a brecha que a rede não fecha.** É por isso que o fechamento verdadeiro é
por header compartilhado na aplicação, e não por security group — ver
[ADR-017](ADR-017-acesso-a-aplicacao-apenas-pelo-gateway.md). Registrar isto aqui evita a
leitura otimista de que o SG resolve o problema.

### 3. A regra 2 é o par estreito da regra 1

```
node_security_group_id  ←  ingress 30080/tcp  ←  aws_security_group.nlb.id
```

Referência por security group, não por CIDR. O NodePort 30080 **não** está aberto para a VPC:
só o NLB alcança. Alguém dentro da VPC que queira contornar o gateway precisa passar pelo NLB
(regra 1), não pode ir direto no node.

A porta 30080 é o único acoplamento declarado entre o Terraform e os manifestos Kubernetes
([ADR-012](ADR-012-gitops-eks-nodeport.md)). Mudar `var.app_node_port` sem mudar
`kubernetes/k8s/overlays/*/service-nodeport.yaml` produz um NLB com target unhealthy e nenhum
erro de apply.

### 4. O SG do banco nasce sem regra de entrada — e isso é a decisão

O `service-track-db-infra` cria o security group do RDS **vazio de ingress**. As regras 3 e 4
são criadas daqui, apontando para o SG do banco lido do SSM.

A razão é dependência circular entre states:

```
o banco precisa da VPC        → rede antes do banco
o stack precisa do endpoint   → banco antes do stack
o SG do banco precisa dos SGs
dos consumidores (EKS, Lambda) → que só existem no stack
```

Se o banco declarasse o próprio ingress, precisaria conhecer o SG do EKS, que é criado depois
dele. Invertendo — o consumidor declara a própria entrada no SG do produtor — a ordem
`rede → banco → stack` fecha sem ciclo. Ver `DB-ADR-003`.

**Consequência operacional que morde:** nunca acrescentar bloco `ingress` inline no
`aws_security_group` do RDS. O Terraform do banco passaria a considerar as regras criadas aqui
como desvio e as removeria a cada apply, derrubando a aplicação de forma intermitente e difícil
de atribuir.

### 5. Egress aberto na Lambda e no RDS

Duas regras de saída são `0.0.0.0/0`. Decisão consciente, não padrão esquecido:

**Lambda:** precisa de RDS, SSM, resolução DNS e do endpoint do próprio serviço. Fechar exigiria
interface endpoints (~US$ 7/mês cada por AZ) ou uma lista de prefixos mantida à mão. Em uma
conta que é recriada toda semana, a lista desatualiza e o sintoma é autenticação quebrada.

**RDS:** o PostgreSQL não abre conexão de saída no uso normal. A regra é herdada do módulo e
inofensiva na prática; está listada para não ser lida como esquecimento.

O trade-off aceito: egress aberto significa que um processo comprometido dentro da VPC tem
saída livre para a internet, através do NAT. A mitigação real neste projeto é o tempo de vida do
ambiente — horas, não meses — e não o filtro de saída.

### 6. Nada é exposto por IP público

Nenhum SG do projeto tem regra de entrada com origem `0.0.0.0/0`. O RDS é
`publicly_accessible = false`, o NLB é `internal = true` e os nodes ficam só em subnet privada.
A única porta pública do sistema é a do API Gateway, que é serviço gerenciado fora da VPC e não
tem security group.

## Consequências

### Positivas

- Quatro regras de entrada no sistema inteiro, todas listadas em uma tabela.
- A inversão do ingress do banco elimina o ciclo entre states sem `depends_on` entre
  repositórios.
- Três das quatro regras usam referência a security group, que sobrevive à troca de CIDR.

### Negativas

- A regra 1 é larga por limitação da AWS, e a rede sozinha não garante acesso apenas pelo
  gateway. O controle real está na aplicação, fora do Terraform.
- Egress aberto em dois SGs.
- As regras 3 e 4 vivem em repositório diferente do recurso que protegem. Quem lê só o
  `service-track-db-infra` vê um security group sem entrada e pode concluir que o banco está
  inacessível.

### Impacto em ambiente efêmero

Todos os SGs e todas as regras são recriados a cada apply. Os IDs mudam, então nada pode ser
fixado em script ou documentação — o SG do banco é publicado no SSM em
`/servicetrack/<env>/db/security-group-id` e lido de lá. Aplicar o stack antes do banco falha
com mensagem explícita, não com erro de atributo inexistente.

## Alternativas consideradas

**Regra 1 restrita aos CIDRs das subnets privadas.** Mais estreita que a VPC inteira.
Descartada porque quebra silenciosamente ao acrescentar AZ, e porque não resolve o problema de
fundo: quem está na subnet privada continua alcançando o NLB.

**Network Policy no Kubernetes para complementar.** Fecharia o tráfego pod a pod, que hoje é
livre. Descartada por ora: exige trocar o VPC CNI por Calico ou habilitar o suporte a Network
Policy do próprio CNI, e o ganho é pequeno em um cluster que roda uma aplicação só. Vale
reabrir se surgir um segundo workload.

**Ingress do banco declarado no `service-track-db-infra` com os SGs passados por variável.**
Manteria as regras junto do recurso protegido. Descartada porque transformaria o `terraform
plan` do banco em dependente de um apply futuro do stack — exatamente o ciclo que a separação
de states existe para quebrar.
