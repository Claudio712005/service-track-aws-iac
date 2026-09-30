# IAC-ADR-030: exposição do ArgoCD é escolhida na execução da esteira

## Data
29/09/2026

## Status
Aceita. Emenda a linha "HML sem LoadBalancer do ArgoCD" do [`IAC-ADR-014`](ADR-014-estrategia-de-custo-conta-estudante.md),
que deixa de ser corte fixo e passa a ser o padrão do ambiente.

---

## Contexto

O `IAC-ADR-014` cortou o `Service type=LoadBalancer` do `argocd-server` em HML para economizar
~US$ 16/mês, deixando o acesso por `kubectl port-forward`. O valor estava escrito no código:
`argocd_expose_lb = false` em `iac/environments/hml/main.tf`, `true` em `prd`.

Na prática existem dois usos diferentes do mesmo ambiente:

- **Trabalho do dia a dia**, onde `port-forward` resolve e o LoadBalancer é só custo;
- **apresentação e demonstração**, onde abrir a interface do ArgoCD num endereço é o ponto, e
  parar para explicar um `port-forward` atrapalha.

Com o valor fixo no código, alternar entre os dois exigia um pull request. Num ambiente que é
destruído e recriado toda semana, isso põe uma decisão de conveniência no caminho crítico — o
mesmo problema que o `IAC-ADR-029` resolveu para o identificador da conta.

Vale registrar que o custo em dinheiro é pequeno: US$ 16/mês é cerca de **US$ 0,02 por hora**, e
o ambiente vive horas, não meses. O custo relevante é operacional: LoadBalancer criado pelo
Kubernetes é justamente o que obriga `scripts/aws-lb-cleanup.sh` antes do `destroy`, senão a
remoção da VPC falha por ELB e ENI órfãos (`IAC-ADR-006`).

## Decisão

A exposição passa a ser **escolha de cada execução**, com três estados:

| Escolha | Efeito |
|---|---|
| `padrao` | não passa `-var`; vale o default do ambiente — `false` em HML, `true` em PRD |
| `sim` | `-var=argocd_expose_lb=true` |
| `nao` | `-var=argocd_expose_lb=false` |

O estado intermediário `padrao` existe para que **PRD não mude de comportamento** quando ninguém
escolhe nada. Um input booleano com default `false` desligaria o LoadBalancer de PRD por omissão,
o que seria uma mudança silenciosa de comportamento disfarçada de conveniência.

A escolha só é aplicada na camada `stack`: a camada `rede` não declara a variável, e `-var` para
variável não declarada é erro do Terraform, não aviso.

Nos ambientes, `argocd_expose_lb` deixa de ser literal e passa a ser variável, com o default de
cada um preservando o comportamento anterior.

## Consequências

- **Alternar entre demonstração e trabalho não exige commit.** É um campo na esteira `Subir
  ambiente` (e na `Terraform`, para quem roda a camada avulsa).
- **A última execução manda.** Subir com `sim` e depois aplicar com `padrao` em HML remove o
  LoadBalancer e a URL do ArgoCD deixa de existir. Isso é o comportamento desejado do Terraform,
  não efeito colateral, mas surpreende quem espera que a escolha "fique".
- **Quem escolhe `sim` assume o `aws-lb-cleanup.sh`.** Sem ele, o `destroy` da rede falha. O
  script já era obrigatório no ritual; com a exposição opcional, ele passa a ser condicionalmente
  crítico em HML também.
- O resumo da esteira continua imprimindo a URL quando ela existe e o comando de `port-forward`
  quando não existe. Nada a mudar ali: ele já decide pelo output.
- PRD segue com LoadBalancer por padrão. Desligar lá passou a ser possível (`nao`), o que antes
  exigia alteração de código.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Manter `false` fixo em HML e usar sempre `port-forward` | resolve custo e ignora o caso da apresentação, que é metade do uso do ambiente |
| Ligar `true` fixo em HML | paga LoadBalancer no uso diário e torna o `aws-lb-cleanup.sh` obrigatório em toda destruição de HML |
| Input booleano com default `false` | desligaria o LoadBalancer de PRD por omissão — mudança de comportamento silenciosa |
| Ingress com host e ACM | precisaria de controller de Ingress e certificado, custo e peça nova para expor uma interface interna |
| `argocd_expose_lb` num `tfvars` por ambiente | o valor volta a viver em arquivo versionado, que é exatamente o que se quer evitar |
