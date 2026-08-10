# Detalhes de implementação

Fatos não óbvios do Terraform e dos scripts deste repositório: por que um atributo tem aquele
valor, e o que quebra ao mudá-lo.

**O porquê das decisões está nos ADRs.** Aqui fica só a mecânica que não cabe numa decisão
arquitetural mas que custa caro descobrir de novo. Este arquivo existe porque o código não
leva comentários; ao alterar um módulo, atualizar a seção correspondente.

---

## `modules/vpc-link`

**`enable_cross_zone_load_balancing = true`.** Os nodes podem estar concentrados em uma AZ só
— em HML o node group tem `desired_size = 1`. Sem cross-zone, o nó do NLB na outra AZ fica sem
alvo e metade das requisições morre. Ver [ADR-023](adr/ADR-023-dimensionamento-de-compute-por-ambiente.md).

**`preserve_client_ip` desligado.** Faz a origem do tráfego no node ser o NLB, não o cliente
original. É o que permite restringir o NodePort ao security group do NLB em vez de liberar a
VPC inteira. Nada se perde: o IP real do usuário chega pelo `X-Forwarded-For` do API Gateway.
Ver [ADR-025](adr/ADR-025-regras-de-security-group.md).

**`deregistration_delay` curto.** Sem isso o target group segura os nodes por 300 s e o
`terraform destroy` arrasta. Importa porque destruir é rotina aqui.

**O NLB é criado pelo Terraform, não pelo Kubernetes.** O VPC Link precisa do ARN do load
balancer em tempo de apply. Um `Service type=LoadBalancer` só existiria depois do ArgoCD
sincronizar, e o Terraform não teria como referenciá-lo. Ver
[ADR-003](adr/ADR-003-integracao-backend-eks-vpc-link.md).

**O ASG do node group é registrado no target group**, então nodes que entram e saem por
autoscaling são registrados automaticamente.

---

## `modules/api-gateway`

**Esquema de segurança com o authorizer desligado.** Vira um `http/bearer` que o API Gateway
ignora — existe apenas no contrato. Ligado, vira o authorizer custom aplicado a toda operação
que referencia `bearerAuth`; rotas com `security: []` seguem abertas. Ver
[ADR-007](adr/ADR-007-lambda-authorizer-opcional.md).

**A permissão de invocação do authorizer usa wildcard.** O authorizer é criado pela importação
do OpenAPI, então não existe recurso Terraform para referenciar no `source_arn`.

**Usage plan dedicado por consumidor.** Quem declara `throttle` ou `quota` próprios ganha um
plano só seu; os demais compartilham o plano do ambiente.

**WAF.** Regra rate-based por IP de origem: acima do limite em janela de 5 min, o IP é
bloqueado até cair abaixo. Escopo `REGIONAL`, associado ao stage do REST API. Complementa o
usage plan, que limita por API key — o WAF barra flood distribuído e anônimo antes de gastar a
Lambda ou o backend. Ligado só onde o config declara `waf.enabled`, hoje apenas PRD. Ver
[ADR-011](adr/ADR-011-rate-limiting-defesa-em-camadas.md).

---

## `modules/stack`

**O contrato EXT fica fora de `iac/`.** A partir de `iac/modules/stack`, são três níveis acima
até a raiz do repositório.

**A chave pública não é um segredo novo.** Já é entregue à Lambda de autenticação por
`lambda_extra_env`; o authorizer reusa a mesma.

**O bootstrap do GitOps é o único passo imperativo.** Um `null_resource` aplica o AppProject e
o app-of-apps com `kubectl` depois que o ArgoCD sobe. A partir daí o Argo sincroniza a
aplicação a partir do git, e os pods passam a aparecer no console como recursos do app — antes
o deploy era `kubectl` solto, fora do rastreio do Argo. Roda só quando os manifests mudam ou
no primeiro apply.

---

## `modules/lambda-authorizer`

**O trigger de rebuild é o hash do código-fonte**, não o artefato compilado: no primeiro
`plan` o binário ainda não existe.

**`depends_on` defere a leitura do artefato para o apply**, depois do build, pelo mesmo motivo.

**A compilação é `go build` na máquina do apply** (arm64). Não há imagem de container, então o
apply continua em uma fase só — mas **exige Go instalado** no runner. Ver
[ADR-007](adr/ADR-007-lambda-authorizer-opcional.md).

**Runtime `provided.al2023`, arm64, sem VPC.** A verificação só precisa da chave pública, que
vem do ambiente.

---

## Esteiras

**`terraform.yml` — setup de Go.** O módulo do authorizer compila o binário no apply
(`null_resource`). Só faz diferença com `enable_jwt_authorizer = true`, mas o setup é barato e
mantém o job correto nos dois casos.

**`contract.yml` — divergência de consumidores é esperada.** A lista pode diferir entre
ambientes de propósito, para dar limites dedicados a um consumidor em PRD.

---

## Scripts

**`gen-local-jwt-keys.sh`.** Gera o par RS256 do overlay `local` (kind). As chaves são de
desenvolvimento, descartáveis e **não versionadas** (`*.pem` está no `.gitignore`). Rodar uma
vez ao preparar o ambiente local. Produção não usa estas chaves: lá o secret
`service-track-jwt` é entregue fora do git ([ADR-013](adr/ADR-013-chaves-jwt-fora-do-git.md)).

Os formatos gerados são PKCS#8 (`BEGIN PRIVATE KEY`) e SPKI (`BEGIN PUBLIC KEY`) — os que o
SmallRye JWT do Quarkus lê por padrão. Gerar em PKCS#1 faz a aplicação subir e falhar só na
primeira validação de token.

---

## Roles do banco: hook de PreSync do ArgoCD

As roles de runtime são criadas por um Job em `kubernetes/k8s/components/db-init/`, incluído
pelos overlays `hml` e `prod` como componente Kustomize. Não é um recurso comum: leva
`argocd.argoproj.io/hook: PreSync`, então roda **antes** do Deployment sincronizar, e a sync
falha se ele falhar. É o que garante que `flyway_user` exista antes do Flyway subir.

**Por que o ConfigMap do script também é hook.** Recursos comuns só são aplicados na fase de
sync, que acontece depois dos hooks de PreSync. Se o ConfigMap não fosse hook, o Job subiria
antes dele existir e montaria um volume vazio. Os dois são `PreSync`, com `sync-wave` 0 para o
ConfigMap e 1 para o Job.

**`disableNameSuffixHash` neste gerador.** O Kustomize acrescenta hash ao nome do ConfigMap por
padrão, o que serve para forçar restart de pod quando a config muda. Aqui o consumidor é um Job
recriado a cada sync, então o hash não agrega — e o nome fixo `db-init-script` é o que a lista
de recursos órfãos do AppProject já referencia.

**`hook-delete-policy: BeforeHookCreation`.** Job é imutável: reaplicar um com spec diferente
falha. Apagar o anterior antes de criar o novo é o que permite alterar o script sem erro de
campo imutável.

**Por que não roda do laptop.** O RDS é `publicly_accessible = false` e o security group dele só
aceita os nodes do EKS e a Lambda. Um `psql` de fora da VPC não alcança — daí o Job rodar dentro
do cluster. O `service-track-db-infra/scripts/aplicar-roles.sh` faz o mesmo trabalho, mas só
funciona de dentro da VPC.

**O host vem do secret.** `db-init-creds` é criado no apply por `scripts/app-secrets-bootstrap.sh`
a partir do SSM, e carrega `POSTGRES_HOST` e `POSTGRES_PORT` além das credenciais. O Job mapeia
esses valores para `PGHOST`, `PGPORT` e `PGPASSWORD`, que é o que o `psql` lê.

