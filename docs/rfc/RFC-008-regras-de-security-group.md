# RFC-008 — Regras de security group e a fronteira entre states

- **Status:** implementado
- **Data:** 2026-07-31
- **ADR resultante:** [025](../adr/ADR-025-regras-de-security-group.md)

## 1. Problema

Security group é a única fronteira de rede aplicada no projeto: sem NACL customizada, sem
Network Policy, e o NLB não filtra. Mesmo assim as regras estavam espalhadas por três módulos e
dois repositórios, sem lugar único que respondesse "quem alcança o quê".

Duas escolhas pareciam defeito na leitura do código:

1. A entrada do NLB usa **CIDR da VPC inteira**, enquanto todas as outras usam referência a
   security group.
2. O security group do RDS é criado **sem nenhuma regra de entrada**, em outro repositório.

## 2. Restrições

**ENIs do VPC Link não são referenciáveis por security group.** A AWS não expõe um SG para
elas. Não existe forma de escrever `source_security_group_id` para a origem do tráfego do
gateway.

**Dependência circular entre states.** O banco precisa da VPC; o stack precisa do endpoint do
banco; o SG do banco precisaria dos SGs do EKS e da Lambda, que só existem no stack.

**Ambiente efêmero.** Todos os IDs de SG mudam a cada apply. Nada pode ser fixado.

**`LabRole`.** Sem IRSA, o que empurra a Lambda para egress aberto em vez de endpoints com
política fina.

## 3. Opções avaliadas

### Entrada do NLB: como estreitar

| Opção | Alcance | Problema |
|---|---|---|
| CIDR da VPC | VPC inteira | mais largo que o necessário |
| CIDRs das subnets privadas | só privadas | quebra ao acrescentar AZ, e ninguém lembra |
| Referência a SG | exato | **impossível**, o VPC Link não tem SG |

Adotado o CIDR da VPC. A opção do meio é mais estreita, mas falha silenciosamente numa mudança
de topologia — e não resolve o problema de fundo, porque quem está na subnet privada continua
alcançando o NLB.

**Conclusão que precisa ficar registrada:** a rede não consegue garantir "acesso apenas pelo
gateway". O controle real é o header compartilhado validado na aplicação
([ADR-017](../adr/ADR-017-acesso-a-aplicacao-apenas-pelo-gateway.md)). Quem ler o security group
esperando encontrar essa garantia vai concluir errado.

### Ingress do banco: onde declarar

| Opção | Consequência |
|---|---|
| No `service-track-db-infra`, com SGs por variável | `plan` do banco passa a depender de um apply futuro do stack — o ciclo volta |
| No `aws-iac`, apontando para o SG lido do SSM | ordem `rede → banco → stack` fecha sem ciclo |

Adotada a segunda: **o consumidor declara a própria entrada no SG do produtor.** É o que
permite os três applies em sequência sem `depends_on` entre repositórios.

Custo da escolha: quem lê só o repositório do banco vê um security group sem entrada e pode
concluir que o banco está inacessível. Documentado nos dois lados (`DB-ADR-003` e
[ADR-025](../adr/ADR-025-regras-de-security-group.md)).

### Egress: fechar ou não

Fechar o egress da Lambda exigiria interface endpoints (~US$ 7/mês cada por AZ) ou uma lista de
prefixos mantida à mão. Numa conta recriada toda semana, a lista desatualiza e o sintoma é
autenticação quebrada — falha cara de diagnosticar, em troca de uma proteção cuja janela de
exploração é de horas.

Adotado egress aberto na Lambda e no RDS, com o trade-off escrito. A mitigação real é o tempo
de vida do ambiente, não o filtro de saída.

## 4. Solução adotada

Quatro regras de entrada no sistema inteiro, três por referência a security group e uma por
CIDR da VPC por impossibilidade técnica. Matriz completa em
[ADR-025](../adr/ADR-025-regras-de-security-group.md).

Nenhum security group do projeto tem entrada com origem `0.0.0.0/0`.

## 5. Riscos conhecidos

| Risco | Mitigação |
|---|---|
| Quem está na VPC alcança o NLB sem passar pelo gateway | Header compartilhado na aplicação, `ADR-017` |
| Bloco `ingress` inline no SG do RDS removeria as regras criadas daqui a cada apply | Proibição explícita em `DB-ADR-003` e no `CLAUDE.md` do repositório do banco |
| Mudar `var.app_node_port` sem mudar o overlay gera target unhealthy sem erro de apply | Acoplamento declarado em `ADR-012` e no diagrama de deployment |
| Egress aberto dá saída livre a processo comprometido | Tempo de vida curto do ambiente |

## 6. Evolução possível

- Network Policy no cluster para fechar tráfego pod a pod, se surgir um segundo workload.
  Exige trocar o CNI ou habilitar o suporte do VPC CNI.
- Interface endpoints para SSM e Secrets Manager, permitindo fechar o egress da Lambda — só se
  paga quando houver mais de uma função na VPC.
- Prefix list gerenciada para as origens do NLB, se a AWS passar a expor SG para ENIs de VPC
  Link.
