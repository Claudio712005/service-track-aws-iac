# Acoplamentos e armadilhas da infraestrutura

O que o desenho mostra, mas não explica. Extraído de `docs/diagramas/deployment.md` e
`rede.md` em 13/09/2026, quando os diagramas passaram a ser mantidos em
[`diagramas/arquitetura-aws.drawio`](diagramas/arquitetura-aws.drawio).

**Fonte de verdade:** `iac/modules/stack/`, `kubernetes/k8s/overlays/<env>/` e
`kubernetes/argocd/`.

---

## Acoplamentos

**NodePort 30080** é o único contrato declarado entre o Terraform e os manifestos. O `base` do
Kustomize é `ClusterIP`; o NodePort vem do overlay. Mudou de um lado, muda dos dois
(`IAC-ADR-012`).

**O ArgoCD lê deste repositório, não do da aplicação.** A aplicação publica a imagem e dispara
`repository_dispatch`; quem reescreve `newTag` no overlay é a esteira daqui (`IAC-ADR-015`).
Essa inversão é o que permitiu remover `infra/` e `k8s/` da API.

**Os segredos não vêm do Git.** Nada que o ArgoCD gerencia contém senha. O bootstrap lê do SSM
e cria os Secrets no cluster (`IAC-ADR-022`), porque External Secrets com IRSA está bloqueado
pela `LabRole` do AWS Academy.

**Ambiente e diretório usam o mesmo nome.** `iac/environments/prd/` aplica a infraestrutura e
`kubernetes/k8s/overlays/prd/` é o que o ArgoCD sincroniza. Até 13/09/2026 o overlay chamava-se
`prod` enquanto o ambiente era `prd`, e o stack monta o caminho a partir de `var.environment` —
o apply de PRD quebrava em `filesha1`, e o bump de imagem procurava um diretório inexistente.

**Só `prd` tem HPA.** `kubernetes/k8s/overlays/prd/hpa.yaml` define 2..4 réplicas com CPU a
70% e memória a 80%. As 4 **não** cabem em um único `t3.medium`: o node entrega 17 slots de pod
e a plataforma já ocupa a maior parte, então PRD roda com dois nodes fixos (`IAC-ADR-023`).
Não há Cluster Autoscaler — `max_size` é teto, não elasticidade.

O overlay `hml` não sobrescreve réplicas e roda no valor do `base`, coerente com o enxugamento
de HML por custo (`IAC-ADR-014`). Ao mexer nesse teto, rever o orçamento de conexões do banco
(`DB-ADR-004`).

**A memória do HPA se mede contra `requests`, não contra `limits`.** A imagem roda com
`-XX:MaxRAMPercentage=75.0`, que dimensiona o heap pelo *limit*. Enquanto `limits` valia o
dobro de `requests`, a JVM ficava autorizada a passar do request antes de qualquer tráfego, e
o HPA lia 121% de utilização em repouso. `requests.memory` subiu para 448Mi em 13/09/2026.

**Primeiro apply de um ambiente deixa os pods em `ImagePullBackOff`.** O ECR nasce vazio no
mesmo apply que cria o cluster. É esperado até a primeira publicação de imagem, não é defeito.

---

## Rede

**Só o API Gateway é público.** Não há Load Balancer interno-externo para a aplicação: o NLB
é `internal = true`, e os nodes só aceitam tráfego na porta 30080 vindo do SG do NLB. O
acesso direto é fechado por header compartilhado, não por rede — ver `IAC-ADR-017` para o
porquê de a rede sozinha não conseguir fechar.

**O SG do NLB libera a porta 80 de `0.0.0.0/0`, e isso não é uma brecha.** As ENIs do VPC Link
de REST API vivem em VPC gerenciada pela AWS, fora do CIDR desta conta, e a AWS não publica
prefix list para restringir a origem. Restringir ao CIDR da VPC — como estava até 07/09/2026 —
descartava o tráfego legítimo do gateway: a integração respondia 500 após 11 segundos de
timeout, sem nada aparecer no log da aplicação. O que fecha o caminho é o NLB ser `internal`,
não a regra de origem.

**O RDS não nasce aqui.** É do `service-track-db-infra`, aplicado entre a rede e o stack. O
security group do banco nasce sem regra de entrada e é este repositório que cria o ingress
apontando para o SG dos nodes e da Lambda (`DB-ADR-003`).

**A VPC morre a cada `destroy`.** CIDR, IDs de subnet e o DNS do NLB são todos recriados.
Nada aqui pode ser copiado para documentação ou cliente — ver `IAC-ADR-006`.

---

## Ordem de criação

```
1. iac/network/<env>        VPC, subnets, IGW, NAT, rotas
2. service-track-db-infra   RDS dentro das subnets privadas
3. iac/environments/<env>   EKS, Lambda, NLB, VPC Link, gateway, ingress no SG do banco
```

Destruir é o inverso, e `scripts/aws-lb-cleanup.sh` precisa rodar antes, senão a remoção da
VPC falha por ENI órfã do NLB.
