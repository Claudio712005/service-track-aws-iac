# Compose da plataforma

Sobe **a plataforma inteira na máquina**: os cinco microsserviços, o banco próprio de cada um,
o Redis, o broker, e a pilha de observabilidade com Grafana. Serve a desenvolvimento integrado
e a demonstração local — **não é** o desenho de `hml` nem de `prd`.

Cada microsserviço tem o seu próprio `docker-compose.yml`, que sobe **aquele serviço sozinho**
com as dependências dele. Este é o único lugar onde os cinco sobem juntos e conversam de
verdade: é a diferença entre exercitar um serviço e exercitar a saga.

> **Por que isto vive aqui.** O `IAC-ADR-026` diz que nenhum módulo deste repositório conhece
> nome de serviço, e o `IAC-ADR-033` concentra a citação de microsserviço num arquivo só. Um
> compose que sobe a plataforma precisa nomear os cinco, com caminho de build. A exceção está
> registrada e justificada no `IAC-ADR-037` — não é descuido, e não abre precedente para
> Terraform nem para manifesto.

---

## Pré-requisitos

1. **Docker com o plugin `compose`**, e o daemon rodando.
2. **Os seis repositórios clonados como irmãos**, porque o build é a partir do código-fonte:

```
service-track/
├── service-track-aws-iac/          <- você está aqui
└── microsservicos/
    ├── service-track-catalogo/
    ├── service-track-usuarios-veiculos/
    ├── service-track-ordem/
    ├── service-track-bff/
    └── service-track-checkout/
```

   Layout diferente é suportado: aponte `REPOS_DIR` no `.env` para a raiz que contém
   `microsservicos/`.

3. **Cerca de 5 GB de memória livre para o Docker.** São 18 contêineres, cinco deles JVM.

## Subir

```bash
cd compose
cp .env.exemplo .env
docker compose up -d --build
```

A primeira subida compila cinco imagens e leva vários minutos. Depois:

```bash
docker compose ps                 # quem está de pé e quem está unhealthy
docker compose logs -f bff        # um serviço
docker compose down               # para, preservando os dados
docker compose down -v            # para e apaga os dados
```

## Onde cada coisa atende

| | Endereço | Observação |
|---|---|---|
| BFF | http://localhost:8083 | a entrada; é por aqui que se exercita o sistema |
| catálogo | http://localhost:8080 | |
| usuários e veículos | http://localhost:8081 | |
| ordens | http://localhost:8082 | dono da saga e do broker |
| checkout | http://localhost:8084 | |
| Grafana | http://localhost:3000 | `admin`/`admin`, já com o painel da plataforma |
| Prometheus | http://localhost:9090 | |
| Tempo | http://localhost:3200 | |
| Loki | http://localhost:3100 | |
| Postgres do catálogo | `localhost:5432` | `st_cat` / `st_cat_user` / `st_cat_local` |
| Postgres de ordens | `localhost:5433` | `st_ord` / `st_ord_user` / `st_ord_local` |
| Postgres de usuários | `localhost:5434` | `st_usu` / `st_usu_user` / `st_usu_local` |
| Postgres do checkout | `localhost:5435` | `st_chk` / `st_chk_user` / `st_chk_local` |
| MongoDB `ST_INS` | `localhost:27017` | sem autenticação |
| Redis | `localhost:6379` | |
| Kafka | `localhost:29092` | de dentro da rede é `kafka:9092` |

Toda porta é configurável no `.env`. As portas de aplicação seguem de propósito a ordem dos
NodePorts do cluster — 30080 a 30084 viram 8080 a 8084.

## O que este compose reproduz de verdade

- **Quatro bancos relacionais separados, um por serviço.** Não é um Postgres com quatro
  databases: nenhum serviço alcança o banco de outro, e isso é regra, não detalhe.
- **Um broker só, e ele é de ordens** (`GLOBAL-ADR-011`). O contêiner se chama `st-ord-kafka`
  justamente para não deixar dúvida sobre de quem é. Catálogo e ordens apontam para ele.
- **Os três tópicos criados antes das aplicações subirem**, pelo passo `topicos`, porque
  `KAFKA_AUTO_CREATE_TOPICS_ENABLE` é `false` nos dois serviços.
- **O baseline de cada banco aplicado na primeira subida**, montando o `db/postgres` de cada
  repositório em `docker-entrypoint-initdb.d`. Os serviços rodam `ddl-auto: validate`, então
  banco vazio **recusa** subir — `CrashLoopBackOff` até o baseline existir é esperado.
- **O trace atravessando os cinco serviços e a fila.** O agente do OTel está ligado em todos,
  exportando para o Tempo, e todos amostram 100%.
- **O BFF chamando os serviços de verdade.** Ele sobe **sem** o perfil `dev`, de propósito: com
  `dev` ele usa dublês em memória e não chama ninguém.

## O que ele não reproduz, e você precisa saber

- **Não há API Gateway, nem Lambda, nem token.** `ST_BFF_JWT_ENABLED=false` porque não existe
  emissor aqui. Em `hml` e `prd` a Lambda emite e o BFF valida com a chave do ambiente
  (`IAC-ADR-036`); localmente as rotas do BFF ficam abertas. Para exercitar a validação, gere um
  par RS256, aponte `ST_BFF_JWT_PUBLIC_KEY` para a pública e ligue a flag.
- **O Mongo roda em contêiner.** Em `hml` e `prd` ele é Atlas M0, fora do cluster
  (`GLOBAL-ADR-012`), porque `emptyDir` perdia categoria e insumo em qualquer rollout. Aqui o
  volume é nomeado e o dado sobrevive a `down`, mas não a `down -v`.
- **O checkout não fala com o Mercado Pago sem credencial.** Sem `MERCADO_PAGO_ACCESS_TOKEN`,
  criar cobrança falha na chamada ao provedor. A verificação de assinatura do webhook vem
  desligada (`MERCADO_PAGO_VERIFY_SIGNATURE=false`) porque não há notificação real chegando.
  **Nunca commitar o token:** `compose/.env` está no `.gitignore`.
- **Não há exporter de Postgres.** O painel cobre aplicação, JVM, pool de conexão, Redis e
  mensageria; métrica de dentro do banco exigiria quatro contêineres a mais por pouco retorno.
- **Grafana aqui é local, não o Grafana Cloud** do `GLOBAL-ADR-009`. A pilha é a mesma —
  Prometheus, Tempo, Loki — mas o destino é outro.

## Reaplicar o baseline de um banco

O `docker-entrypoint-initdb.d` **só roda com volume vazio**. Mudou o baseline ou o seed de um
serviço:

```bash
docker compose rm -sf postgres-catalogo
docker volume rm service-track_postgres-catalogo
docker compose up -d postgres-catalogo
docker compose restart catalogo
```

Para o Mongo, trocar `postgres-catalogo` por `mongo` e `service-track_postgres-catalogo` por
`service-track_mongo`.

## Quando algo não sobe

| Sintoma | Causa provável |
|---|---|
| aplicação em `unhealthy`, log com `Schema-validation` | baseline não aplicado — volume do banco já existia vazio |
| `address already in use` | outro compose de serviço já está de pé, ou um Postgres local; ajuste a porta no `.env` |
| build falha com `path not found` | `REPOS_DIR` errado, ou um dos repositórios não está clonado |
| catálogo ou ordens sobem e nada consome | o passo `topicos` falhou; `docker compose logs topicos` |
| BFF responde 503 em tudo | dependência ainda subindo; `docker compose ps` mostra quem está `unhealthy` |
| Grafana sem dado | aplicação sem `/actuator/prometheus` exposto, ou alvo `down` em http://localhost:9090/targets |
