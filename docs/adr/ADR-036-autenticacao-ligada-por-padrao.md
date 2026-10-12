# ADR-036: autenticação é passo normal da subida, e não depende mais do banco compartilhado

## Data
12/10/2026

## Status
Aceita. **Supera a [`ADR-027`](ADR-027-autenticacao-e-borda-desligadas-por-flag.md)**, que deixava
`habilitar_autenticacao` e `habilitar_borda` em `false`.

---

## Contexto

A `ADR-027` desligou as duas flags em 22/09/2026 por **um motivo concreto**: a Lambda lia as
tabelas `usuarios` e `usuario_roles` no RDS do `service-track-db-infra`, escritas pelas migrations
do monólito. Manter a Lambda de pé obrigava a manter aquele RDS de pé, o que reforçava o
acoplamento que a Fase 4 proíbe (`A-06`) e custava um banco por decisão que ainda não existia.

**Esse motivo deixou de existir em 05/10/2026.** A Lambda passou a chamar
`POST /credenciais/verificacao` no `service-track-usuarios-veiculos`, e dela saíram o datasource,
o `schema.sql` e o Bcrypt local. Verificado em 12/10/2026 no repositório da Lambda:

- `application.properties` **não tem** nenhuma propriedade `quarkus.datasource.*`
- `build.gradle.kts` tem `quarkus-hibernate-validator` — validação de bean, não ORM. Nenhum JDBC,
  nenhum Panache
- nenhuma referência a `POSTGRES_` em `src/`

A plataforma, porém, continuava se comportando como se o banco fosse necessário: injetava
`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` e
`DB_POOL_MAX_SIZE` na env da Lambda, lia **sete parâmetros** `/servicetrack/<env>/db/*` do SSM,
abria **5432** no security group do banco, e a esteira exigia o `db-infra` aplicado.

## Decisão

### 1. As três flags passam a ser `true` por padrão nos dois ambientes

| Flag | Antes | Agora |
|---|---|---|
| `habilitar_autenticacao` | `false` | **`true`** |
| `habilitar_borda` | `false` | **`true`** |
| `habilitar_entrada_do_bff` | `false` | **`true`** |

Autenticação deixa de ser passo opcional: um `apply` entrega a plataforma **com** Lambda, gateway
público e o caminho até o BFF. As três andam juntas por dependência real, não por conveniência:

```
habilitar_borda          -> exige habilitar_autenticacao   (a rota publicada e o login)
habilitar_autenticacao   -> exige habilitar_entrada_do_bff (a Lambda alcanca usuarios pelo NLB)
```

As duas dependências são **validadas no `plan`**, cada uma com mensagem própria. Desligar continua
possível por `-var`, e desligar a autenticação sozinha deixa o gateway sem rota — por isso a
validação existe.

### 2. O acoplamento morto com o banco compartilhado sai

Saem da plataforma: as cinco variáveis `POSTGRES_*` e o `DB_POOL_MAX_SIZE` na env da Lambda, as
seis variáveis de banco do módulo `lambda`, as sete leituras de `/servicetrack/<env>/db/*`, a
regra de ingress 5432 e o output `rds_endpoint`.

**Consequência que muda o ritual:** `habilitar_autenticacao = true` **não exige mais o
`service-track-db-infra` aplicado**. A regra "rede → banco → stack" vale para o monólito, que será
arquivado, e não para a autenticação.

### 3. A dependência real é o serviço de usuários, e ela é verificada

Quem confere a credencial é o `service-track-usuarios-veiculos`. Isso virou **duas verificações
na esteira**, em momentos diferentes, porque são duas coisas diferentes:

| Quando | O que confere | Se falta |
|---|---|---|
| Antes do `plan` | `/servicetrack/<env>/usuarios-veiculos/db/endpoint` existe no SSM | **erro**, apontando a esteira Infra daquele repositório |
| Depois do `apply` | o `Deployment` existe no cluster e tem réplica pronta | **aviso**, não erro |

A assimetria é deliberada. A infraestrutura do serviço de usuários é independente do cluster e
pode ser exigida antes. O **pod** não: num ambiente novo o cluster nasce no mesmo `apply`, e o
ArgoCD só sincroniza depois. Exigir pod pronto criaria um ovo-e-galinha e faria a subida de um
ambiente limpo falhar sempre.

Então, em ambiente novo, a ordem natural é: plataforma sobe → `POST /autenticacao` responde erro →
ArgoCD sincroniza e o CD do serviço de usuários publica a imagem → login funciona. O aviso da
esteira diz exatamente isso, para ninguém tratar como defeito.

## Consequências

- **Custo sobe.** Lambda, ECR dela, API Gateway e NLB passam a existir em todo `apply`. O NAT e o
  control plane do EKS continuam sendo os maiores itens, e o NLB é o terceiro. Em troca, HML deixa
  de subir pela metade.
- **A chave RS256 passa a existir sempre**, e com ela `/servicetrack/<env>/jwt-public`. É o que a
  esteira **Segredos** do BFF consome: ela deixa de falhar por ausência do parâmetro.
- **O `db-infra` deixa de ser pré-requisito da plataforma.** Ele continua existindo para o
  monólito, e o README dele passa a dizer isso.
- **A superfície diminui**: a porta 5432 não é mais aberta para a Lambda, e cinco variáveis com
  credencial de banco saem da env dela — e, com elas, do state (`I-16`).
- **O primeiro `apply` de um ambiente novo entrega login que ainda não funciona.** Documentado,
  avisado pela esteira, e resolvido pela sincronização do ArgoCD. Não é defeito.
- **A `GLOBAL-RFC-009` deixa de bloquear isto.** A `ADR-027` condicionava religar a flag a decidir
  "quem é dono dos dados de usuário". Já está decidido e implementado: o dono é o
  `service-track-usuarios-veiculos`, e a Lambda só pergunta.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Manter `false` e ligar por `-var` quando precisar | é o estado que fez a autenticação nunca subir em `hml`. Passo que só acontece quando alguém lembra não é passo |
| Ligar a autenticação e deixar a borda `false` | a Lambda só é alcançável pela borda; sem ela, existe uma função que ninguém chama |
| Exigir réplica pronta do serviço de usuários antes do `apply` | ovo-e-galinha: num ambiente novo o cluster nasce nesse mesmo `apply` |
| Manter as variáveis `POSTGRES_*` "por segurança" | credencial de banco na env de uma função que não tem banco, gravada no state. Segurança nenhuma |
| Transformar a flag em escolha da esteira, como `expor_argocd` | escolha por execução é para o que varia. Autenticação não varia: é parte do sistema |
