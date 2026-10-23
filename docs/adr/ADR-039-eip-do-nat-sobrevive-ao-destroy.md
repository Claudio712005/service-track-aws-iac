# ADR-039: o EIP do NAT Gateway vive num state de bootstrap e sobrevive ao destroy do ambiente

## Data
21/10/2026

## Status
Aceita. Aplica a regra 2 do `GLOBAL-ADR-002` — *recurso que precisa sobreviver vai para um state
de bootstrap separado* — a um recurso que até aqui morria com a camada de rede.

---

## Contexto

O `GLOBAL-ADR-012` moveu o MongoDB do catálogo para o Atlas na camada gratuita. O M0 **não
oferece PrivateLink nem VPC Peering** — os dois exigem M10 ou superior — então o único controle
de acesso disponível é a lista de IPs. O tráfego do cluster sai pelo NAT Gateway, logo é o IP
dele que o Atlas vê.

Aquele ADR aceitou liberar `0.0.0.0/0`, com a justificativa de que a EIP do NAT é criada no
`apply` e muda a cada recriação de ambiente, e que manter a lista afinada exigiria atualizá-la em
todo ciclo.

Em 21/10/2026 a alternativa apertada foi exercitada em `hml`: liberar o IP do NAT com `/32`
funciona, e o esforço é o mesmo de liberar `0.0.0.0/0` — um comando para ler o IP e uma edição no
Atlas. O que incomoda não é a primeira vez, é a repetição.

E ela repete menos do que parecia: o EIP vive no state `servicetrack/<env>-network`, separado do
stack. O escopo `so-o-stack` da esteira de destruição, que é o **padrão**, não encosta nele.
Só `escopo=tudo` libera o EIP.

Ainda assim, `escopo=tudo` é o caminho de quem quer zerar a conta — e é justamente quando o custo
de refazer o cadastro no Atlas aparece, na pior hora: véspera de apresentação, com o catálogo em
`CrashLoopBackOff` por timeout de conexão, sintoma que não aponta para o Atlas.

## Decisão

**O EIP do NAT passa a ser reservado num state de bootstrap**, `servicetrack/bootstrap-rede`, com
`prevent_destroy`. A camada de rede o encontra por tag e o consome; quando não encontra, cria o
EIP dentro de si, como antes.

### A camada de rede descobre por tag, não por remote state

`terraform_remote_state` **falha duro** quando o state apontado não existe. Isso tornaria o
bootstrap um pré-requisito obrigatório de toda subida de rede, e a primeira pessoa a aplicar a
rede sem ter rodado o bootstrap receberia um erro de backend em vez de um ambiente.

Em vez disso, cada root module de rede usa `data "aws_eips"` filtrando por duas tags:

```hcl
data "aws_eips" "nat_reservado" {
  tags = {
    Name  = "${local.name}-nat"
    Layer = "bootstrap-rede"
  }
}
```

Lista vazia significa bootstrap não aplicado, a variável vai nula, e `aws_eip.nat` nasce na
camada de rede com `count = 1`. **O comportamento sem bootstrap é idêntico ao de antes desta
decisão.**

A tag `Layer` é o que evita o auto-casamento: o EIP criado pela camada de rede herda
`Layer = "network"` de `var.tags`, e o reservado carrega `Layer = "bootstrap-rede"`. Sem essa
distinção o filtro encontraria o EIP que a própria camada acabou de criar, e o `Name` sozinho é
igual nos dois.

### O escopo é a conta, não o ambiente

O bootstrap reserva um EIP **por ambiente** numa passada só, com `for_each` sobre
`var.ambientes`. O input `env` da esteira serve apenas para escolher de qual environment do
GitHub ler as credenciais da AWS — está escrito na descrição do input, porque é confuso de outro
modo.

## Consequências

- **O IP liberado no Atlas passa a valer para a vida do projeto.** Um cadastro, uma vez,
  independente de quantos ciclos de ambiente aconteçam.
- **Custo:** AWS cobra todo IPv4 público, ~US$ 0,005/hora. Com o ambiente de pé, o EIP já era
  cobrado como parte do NAT, então o custo **incremental** é só o período em que o ambiente está
  destruído — até ~US$ 3,60/mês por ambiente, no caso de ficar o mês inteiro derrubado. Comparar
  com manter a rede de pé só para preservar o IP, que são ~US$ 32/mês de NAT Gateway.
- **Dois EIP reservados por padrão**, `hml` e `prd`. Quem não usa `prd` pode reduzir
  `var.ambientes` e pagar um só.
- **`prevent_destroy` impede `terraform destroy` neste state.** Remover um EIP de propósito exige
  tirar o ambiente de `var.ambientes` e aplicar, ou remover o `lifecycle`. É atrito deliberado:
  o recurso existe para não ser destruído por acidente.
- **`aws_eip.nat` ganhou `count`**, então o endereço dele no state mudou de `aws_eip.nat` para
  `aws_eip.nat[0]`. Em rede já existente isso exigiria `terraform state mv`. Esta decisão foi
  tomada com `hml` sendo destruído por completo, então não houve migração a fazer — mas quem
  aplicar numa rede viva precisa do `state mv`.
- **A liberação de `0.0.0.0/0` deixa de ser necessária**, e o `GLOBAL-ADR-012` deve ser anotado:
  o custo que ele aceitou tem agora uma saída.

## O que esta decisão deixa em aberto

**O bootstrap da DNS não existe em código.** `iac/bootstrap/dns/` tem zero arquivos rastreados, e
a hosted zone que o `GLOBAL-ADR-002` manda nunca destruir sobrevive apenas enquanto o state no S3
sobreviver — sem Terraform para recriá-la. Perdê-la obriga a refazer a delegação manual no
Registro.br e esperar propagação.

Este ADR cria o primeiro state de bootstrap **versionado** do repositório, e o padrão serve para
a DNS. Versioná-la é trabalho pendente, e é risco maior que o resolvido aqui.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Manter `0.0.0.0/0` no Atlas | funciona, e deixa o cluster aceitando tentativa de autenticação de qualquer origem; com um IP fixo disponível, não há razão para pagar esse preço |
| Destruir sempre com `escopo=so-o-stack` | preserva o EIP e também o NAT: ~US$ 32/mês para guardar um IP de ~US$ 3,60 |
| Private Endpoint ou VPC Peering no Atlas | exigem M10 pago; indisponíveis no M0 |
| Automatizar o cadastro pela Admin API do Atlas | resolve o sintoma e acrescenta uma chave de API como segredo novo, mais um passo na esteira Banco; o IP fixo elimina a necessidade em vez de automatizá-la |
| `terraform_remote_state` em vez de descoberta por tag | torna o bootstrap pré-requisito obrigatório da rede e falha com erro de backend quando ausente |
| EIP no state do stack | o stack é destruído com mais frequência que a rede; seria pior |
