# ADR-040: "Destruir ambiente" passa a destruir também a infraestrutura dos serviços, e duas esteiras são aposentadas

## Data
01/11/2026

## Status
Aceita. Completa o `ADR-038` e aposenta `subir-ambiente.yml` e `bootstrap-state.yml`.

---

## Contexto

O escopo `tudo` da esteira **Destruir ambiente** prometia o que não entregava. Ela destruía o
stack e, opcionalmente, a rede — e **nada** dos microsserviços, cuja infraestrutura vive no state
de cada repositório. Verificado em 01/11/2026: zero menções a catálogo, ordens, checkout,
usuários ou ao `disparar-esteira.sh` no arquivo.

A guarda de pré-destruição não compensava a lacuna: ela confere
`/servicetrack/<env>/db/endpoint`, do `service-track-db-infra`, e **não**
`/servicetrack/<env>/<servico>/db/endpoint`, que é onde os quatro RDS de microsserviço publicam.
Como o `db-infra` não roda desde o `ADR-036`, a guarda passa — e o `destroy` da rede falha com
quatro RDS, quatro subnet groups e quatro security groups dentro da VPC.

Em 21/10/2026 isso custou um ciclo inteiro: a destruição teve de ser feita serviço por serviço,
à mão, descobrindo a ordem no momento.

Separadamente, o `ADR-038` criou a esteira **Orquestrar ambiente**, cujas fases 1 e 3 são
`terraform.yml` com `camada: rede` e `camada: stack` — exatamente o que **Subir ambiente** fazia,
e nada além.

## Decisão

### 1. A destruição espelha a subida

**Destruir ambiente** ganha a fase `1. Infra de <servico>`, em matriz sobre os cinco
repositórios, disparando a esteira `infra.yml` de cada um com `acao=destroy` pelo
`scripts/disparar-esteira.sh` — o mesmo mecanismo da subida. Só com `escopo=tudo`: com
`so-o-stack` o ECR e o RDS de cada serviço devem sobreviver, porque o stack não os contém.

A ordem é a inversa da subida, e é obrigatória: os RDS vivem na VPC, então a rede só pode cair
depois deles.

**A condição do job `stack` precisa de cuidado.** Com `escopo=so-o-stack` a fase de serviços é
**pulada**, e em GitHub Actions um `need` pulado pula o dependente. Sem tratamento, remover
serviços quebraria o escopo parcial. Por isso o `stack` roda com `always()` mais a conferência
explícita de que a fase de serviços não **falhou** nem foi **cancelada** — pulada é aceitável,
falha não é, porque destruir o stack com serviços de pé deixaria a rede impossível de remover.

### 2. Duas esteiras são aposentadas

**`subir-ambiente.yml`** é subconjunto exato das fases 1 e 3 de **Orquestrar ambiente**. Ter dois
caminhos para o mesmo apply convida a rodar o antigo e concluir que o ambiente está de pé quando
falta tudo dos serviços.

**`bootstrap-state.yml`** é desnecessária: o `terraform.yml` chama
`scripts/bootstrap-tfstate.sh` por conta própria, em duas posições. O bucket nasce na primeira
execução de qualquer camada.

**O que substitui o caminho sem token:** a esteira **Orquestrar ambiente** exige `OPS_TOKEN`, e
**Subir ambiente** não exigia. A substituição não é a orquestração — é o dispatch direto de
**Terraform** por camada, que também não exige token e cobre o mesmo apply em dois acionamentos.
Isto importa: num dia em que o `OPS_TOKEN` esteja expirado, a plataforma continua subível.

### 3. O mesmo defeito foi corrigido na subida

Ao escrever a condição do `stack` ficou evidente que o `ADR-038` tinha o mesmo problema, ao
contrário: no orquestrador, `servicos_cd` dependia de `servicos_infra`, que é matriz com
`fail-fast: false`. As pernas saudáveis seguiam, **mas a conclusão do job é `failure` se
qualquer perna falhar**, e isso pulava os cinco CDs.

Observado em 01/11/2026: o Banco do catálogo falhou por falta dos parâmetros do Mongo e
**nenhuma imagem foi publicada**, embora os outros quatro serviços estivessem prontos. O
`fail-fast: false` prometia isolamento e a dependência o anulava.

As fases 5 e 6 passam a usar `always()` com conferência de cancelamento, e a 6 exige `success`
do segredo do JWT — sem ele o BFF não sobe, e mesclar tag não ajuda.

## Consequências

- **`escopo=tudo` passa a fazer jus ao nome.** Cinco destroys de serviço, em paralelo até três,
  depois stack, depois rede.
- **A destruição passa a exigir `OPS_TOKEN`** com Actions no destino, como a subida. Sem ele, o
  caminho é o de 21/10: disparar o `infra.yml` com `acao=destroy` em cada repositório, e então
  **Terraform** com `camada: stack` e `camada: rede`.
- **Uma perna que falhe na fase 5 não impede as outras quatro de publicarem.** O operador perde
  um serviço, não a subida.
- **A guarda de `db-infra` continua como está.** Ela protege contra o RDS do monólito, que é
  outro problema; os RDS de microsserviço agora saem antes por construção, não por conferência.
- **Menos dois botões.** Quem conhecia **Subir ambiente** precisa saber que ela não existe mais —
  o `README` e o `docs/api-gateway/README.md` foram corrigidos, e o `ADR-038` anotado.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Só corrigir a guarda, listando os serviços com RDS vivo | troca uma falha confusa por uma mensagem clara, e mantém o trabalho manual que a mensagem manda fazer |
| Deixar a destruição dos serviços fora, documentando a ordem | é o que existia; custou um ciclo e a ordem não estava em lugar nenhum dentro dos repositórios |
| Manter `subir-ambiente.yml` como plano B sem token | o dispatch de **Terraform** por camada já é esse plano B, sem um segundo arquivo a manter |
| Destruir os serviços em série | cada RDS leva de 8 a 12 minutos; em série são ~50, em paralelo ~12 |
| `fail-fast: true` na matriz de destruição | parar na primeira falha deixa os outros de pé e a rede impossível de remover de qualquer forma |
