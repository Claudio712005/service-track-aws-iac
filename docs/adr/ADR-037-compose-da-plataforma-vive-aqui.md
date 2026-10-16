# ADR-037: o compose que sobe a plataforma inteira vive neste repositório, e é a segunda exceção à ADR-026

## Data
15/10/2026

## Status
Aceita. **Não altera** a [`ADR-026`](ADR-026-plataforma-sem-acoplamento-a-servicos.md) nem a
[`ADR-033`](ADR-033-api-interna-para-o-bff.md): abre uma exceção nomeada, com fronteira escrita.

---

## Contexto

Cada microsserviço tem o seu `docker-compose.yml`, e cada um sobe **aquele serviço sozinho** com
as dependências dele. Isso é deliberado e continua valendo: o overlay `local` e o compose de cada
repositório existem para subir o repositório sem depender de ninguém.

O que não existia é um lugar onde os cinco sobem **juntos**. E a diferença não é de conveniência:

- A **saga** (`GLOBAL-ADR-007`) atravessa ordens e catálogo por mensageria. Com um broker por
  compose, cada serviço fala com o seu próprio Kafka e a saga nunca acontece.
- O **BFF** compõe resposta a partir de três serviços. Sozinho, ele sobe no perfil `dev`, com
  dublês em memória, e não exercita integração nenhuma.
- O **checkout** chama `GET /ordens/{id}` antes de falar com o provedor, porque o valor cobrado
  não vem do cliente. Sem ordens de pé, esse caminho não roda.
- O **trace atravessando a fila** só é observável com produtor, consumidor e coletor no mesmo
  lugar.

Em `hml` e `prd` isso tudo existe junto porque o cluster os coloca junto. Na máquina, não havia
equivalente — e a consequência prática é que a integração só era exercitada em ambiente efêmero,
que é caro de subir e morre a cada apresentação.

## Decisão

**O compose da plataforma vive em `compose/`, neste repositório.**

A razão é a mesma que faz o `kubernetes/` e a descoberta de microsserviços viverem aqui: o
artefato descreve **como as peças se compõem**, e nenhuma das peças é dona dessa composição.
Colocá-lo em qualquer um dos cinco repositórios daria àquele serviço um arquivo que nomeia os
outros quatro, o que é pior.

### Esta é uma exceção nomeada, e a fronteira é esta

A `ADR-026` proíbe **módulo Terraform e bloco `module` por serviço**. A `ADR-033` concentra a
citação de microsserviço em `apis/service-track-api-int/servicos-<ENV>.yaml`, para que os módulos
continuem genéricos.

O compose nomeia os cinco serviços e carrega o caminho de build de cada um. **A exceção vale só
para ele**, e não se estende a:

- Terraform — nenhum módulo e nenhum bloco `module` por serviço, sem mudança;
- manifesto Kubernetes de aplicação — continua no `k8s/` de cada repositório;
- contrato de borda — continua expondo o BFF e nada mais (`ADR-035`);
- esteira — nenhuma esteira deste repositório constrói nem publica imagem de microsserviço.

Dito de outro modo: **o compose descreve a máquina do desenvolvedor, não a AWS.** Se um dia
precisar de credencial da AWS, de `terraform` ou de `kubectl`, a exceção foi extrapolada.

### O caminho dos repositórios é dado, não constante

O build aponta para `${REPOS_DIR:-../..}/microsservicos/<repo>/software`. O padrão corresponde ao
layout de clones irmãos; outro layout muda uma variável no `.env`. É o mesmo princípio do
`servicos-<ENV>.yaml`: o que varia por ambiente entra como dado.

## Consequências

- Integração passa a ser exercitável sem subir `hml`, que é o corte de custo mais eficaz que
  temos. Saga, composição do BFF e trace ponta a ponta rodam na máquina.
- **O compose só funciona com os seis repositórios clonados.** Clone isolado deste repositório
  não sobe a plataforma, e o README diz isso na primeira linha dos pré-requisitos.
- **Não há gateway, Lambda nem token local.** O BFF sobe com a validação de JWT desligada, o que
  é divergência declarada: em `hml` e `prd` a autenticação é passo default (`ADR-036`).
- O Mongo roda em contêiner, divergindo do Atlas de `hml` e `prd` (`GLOBAL-ADR-012`) — a mesma
  divergência que o overlay `local` do catálogo já declara.
- **Duplicação aceita:** a configuração de Prometheus, Tempo, Loki e Grafana existe aqui e também
  no `catalogo` e no `usuarios-veiculos`. Unificar exigiria um repositório de observabilidade, ou
  que um serviço fosse dono da pilha dos outros. A duplicação é o menor dos males enquanto a
  `GLOBAL-RFC-003`/`GLOBAL-ADR-009` não fecharem como a métrica chega ao Grafana Cloud.
- São 18 contêineres e cerca de 5 GB de memória. Não é um compose para deixar de pé o dia todo.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| No repositório do BFF | o BFF é dono da forma da resposta pública, não da topologia; e ganharia um arquivo citando os outros quatro |
| No repositório de ordens, por ser dono do broker | hospedar o broker não dá voz sobre os outros serviços — é exatamente o que o `GLOBAL-ADR-011` já decidiu em outro contexto |
| Num repositório novo só para isto | sétimo repositório, com uma esteira a manter, para um arquivo e cinco configs |
| Em `workspace/` | não é publicável e não acompanha quem clona os repositórios |
| Usar imagens do ECR em vez de build | o ECR morre no `destroy` e exige credencial da AWS; justo o que o compose existe para evitar |
| Um Postgres com quatro databases | contradiz "nenhum serviço acessa o banco de outro" no único lugar onde a regra é fácil de demonstrar |
