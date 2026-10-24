# ADR-038: a plataforma orquestra a subida do ambiente disparando a esteira de cada repositório

## Data
18/10/2026

## Status
Aceita. **Não supera ADR nenhuma.** A posição anterior — "nenhuma esteira daqui dispara outra de
outro repositório" — existia só nas notas locais de trabalho e nunca foi registrada como decisão.
Pela regra 9 do projeto, ela não existia. Esta é a primeira decisão formal neste eixo.

---

## Contexto

Subir um ambiente do zero custava, medido em 17/10/2026 contra as esteiras existentes,
**11 execuções manuais em sequência mais 5 merges de pull request**, distribuídas por sete
repositórios, com a ordem correta existindo apenas na cabeça de quem opera e num runbook fora dos
repositórios.

A ordem não é arbitrária e três das dependências não são óbvias:

1. **O `plan` do stack falha sem o serviço de usuários.** A Lambda chama
   `POST /credenciais/verificacao` e a plataforma exige
   `/servicetrack/<env>/usuarios-veiculos/db/endpoint` no SSM antes do apply (`ADR-036`). Logo o
   Infra daquele repositório entra **entre** a rede e o stack, e não junto com os outros quatro.
2. **A esteira Banco de cada serviço é pulada quando o cluster ainda não existe.** O RDS é
   privado e o baseline só roda de dentro do cluster, então a cadeia Infra → Banco termina com
   `pular=true` e exige uma segunda execução depois do stack. Quem não sabe disso vê a esteira
   verde e o pod em `CrashLoopBackOff`, porque `ddl-auto: validate` recusa banco vazio.
3. **O BFF não sobe sem o segredo do JWT, e ninguém é avisado.** O `infra.yml` dele não encadeia
   o `segredos.yml`, ao contrário dos outros, que encadeiam o Banco. Sem o `Secret`, o volume
   `optional: true` monta vazio, o `jwtDecoder` falha na criação do bean e o contexto não sobe.
   Como o BFF é a única entrada pública (`ADR-035`), o ambiente inteiro fica inalcançável por um
   passo esquecido.

Conhecimento operacional que mora fora dos repositórios é conhecimento que se perde. E a conta é
AWS Academy: o ambiente é destruído depois de cada teste e recriado do zero, então esse custo não
é pago uma vez — é pago toda semana.

## Decisão

**Uma esteira neste repositório orquestra a subida inteira, disparando a esteira do repositório
dono de cada parte e esperando o resultado.** `.github/workflows/orquestrar-ambiente.yml`.

### O que a decisão não é

- **Não é mover trabalho para cá.** Nenhuma esteira de microsserviço foi alterada. A plataforma
  não constrói imagem, não aplica Terraform alheio e não aplica manifesto de ninguém. Ela
  *chama* e *espera*.
- **Não é assumir propriedade.** Cada repositório segue dono da sua infraestrutura, da sua
  imagem e do seu banco. Quem executa é a esteira dele, com os segredos dele, no ambiente dele.
- **Não é o único caminho.** Toda esteira continua disparável à mão, uma a uma. O orquestrador é
  conveniência, não porta obrigatória — e precisa continuar sendo, porque depuração acontece
  passo a passo.

### A dependência que motiva o desenho

`CD da Lambda` **depende do serviço de usuários respondendo no cluster**, não apenas de a Lambda
existir. Tecnicamente a Lambda sobe sem ele: o `ST_USU_BASE_URL` é lido em runtime, e publicar a
imagem funcionaria. O resultado seria um ambiente que **responde e não autentica**, com o erro
aparecendo só no primeiro login.

A plataforma já tratava isso como aviso, no `terraform.yml`. O orquestrador o promove a
**portão**: a fase 7 espera réplica pronta e a fase 8 só então publica a Lambda. É escolha
operacional deliberada — falhar na subida, onde se olha, em vez de na demonstração.

### Grafo

```
1. rede                          (aws-iac)
1b. ip_de_saida                  (aws-iac)            — imprime o EIP do NAT
2. usuarios_infra                (usuarios-veiculos)   — publica o endpoint do passo 3
3. stack                         (aws-iac)             — EKS, ArgoCD, Lambda, gateway, NLB
4a. bff_segredos                 (bff)                 — o passo que ninguem lembra
4b. usuarios_banco               (usuarios-veiculos)   — reexecucao: no passo 2 foi pulado
4c. servicos_infra               (catalogo, ordens, checkout, bff)
5. servicos_cd                   (os cinco)
6. mesclar                       (os cinco PRs de tag)
7. usuarios_pronto               (cluster)             — portao da fase 8
8. lambda_cd                     (lambda)
9. verificar                     (cluster)
```

O input `ate` corta o grafo em quatro profundidades — `plataforma`,
`infraestrutura-dos-servicos`, `imagens-publicadas`, `ambiente-completo` — porque nem toda
subida quer tudo.

### O que o resumo entrega

Tabela fase por fase com dono e resultado, endereço da borda, comandos para alcançar o cluster, e
**diagnóstico escrito para as três falhas previsíveis**: segredo do JWT ausente, PR de tag não
mesclado, serviço de usuários sem réplica. Erro de orquestração sem diagnóstico empurra a pessoa
de volta para o runbook, que é o que esta decisão existe para aposentar.

## Consequências

- **Um token com permissão entre repositórios passa a ser pré-requisito operacional.** O
  `OPS_TOKEN` já existia para propagar credencial da AWS e para a descoberta do ArgoCD; agora
  precisa também de **Actions: read and write** nos repositórios de destino. Sem ele o
  orquestrador falha no primeiro passo, de propósito e com mensagem clara.
- **O raio de alcance desse token cresceu.** Antes ele escrevia segredo e lia repositório; agora
  dispara execução. O dano máximo em caso de vazamento passa a incluir rodar esteira de deploy em
  ambiente efêmero. Aceito: a conta é educacional, os ambientes são descartáveis, e a
  alternativa era conhecimento operacional não versionado.
- **Esperar execução alheia tem corrida, e ela está resolvida em um lugar só.**
  `gh workflow run` não devolve o id da execução que criou. `scripts/disparar-esteira.sh` registra
  o instante antes do dispatch e aceita apenas execução criada depois dele, pegando a mais antiga
  entre as candidatas. Descobrir isso em cada job daria onze implementações divergentes.
- **O merge automático do PR de tag é opcional** (`mesclar_prs_do_cd`), e falha com mensagem onde
  `main` é protegida sem check verde ou sem auto-merge habilitado — hoje `catalogo` e `aws-iac`.
- **A esteira `subir-ambiente.yml` continua existindo**, cobrindo rede e stack. As duas
  compartilham o grupo de concorrência `orquestracao-<env>`, então não disputam o mesmo ambiente.
- **O orquestrador conhece nome de microsserviço**, em duas matrizes. É a terceira exceção ao
  `ADR-026`, depois do `servicos-<ENV>.yaml` (`ADR-033`) e do compose (`ADR-037`), e vale pela
  mesma razão: descreve composição, não infraestrutura. Nenhum módulo Terraform foi tocado.

### Medido em 24/10/2026, antes da primeira execucao

A descoberta da execução remota foi validada contra a API do GitHub, com dispatch real de uma
esteira de CI: nome de arquivo serve como identificador da esteira, o dispatch responde `204`, e o
corte por horário achou a execução correta em **7 segundos**, com uma única candidata. Os sete
segundos confirmam a primeira armadilha documentada em `scripts/disparar-esteira.sh`: consultar
uma vez logo após o dispatch daria falso negativo.

A fase `1b` existe por causa de um incidente de 21/10/2026: o baseline do Mongo falhou com
`tlsv1 alert internal error`, que é como o Atlas recusa IP fora da lista, e o operador não tinha o
IP à mão. Imprimir o endereço de saída logo após a rede torna essa falha legível. A fase `4c`
depende dela de propósito, para o IP aparecer antes do Banco do catálogo rodar.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Manter o runbook fora dos repositórios | é o que existe, e foi o que produziu os três erros de ordem acima; documento não falha alto |
| Encadear dentro de cada repositório, sem orquestrador | resolve parte — e o BFF deveria encadear o Segredos de qualquer jeito — mas nenhum repositório pode conhecer a ordem **entre** repositórios sem passar a depender dos outros |
| `repository_dispatch` em vez de `workflow_dispatch` | não devolve nem execução nem resultado: dispara e esquece, o que é exatamente o que se quer evitar |
| Um Terraform só, aplicando tudo | funde os states, que são separados de propósito para o ECR de cada serviço sobreviver ao `destroy` do stack |
| ArgoCD ApplicationSet com ondas de sync | cobre só o que vive no cluster; Terraform, ECR, RDS e o CD das imagens ficam fora |
| GitHub Actions `environment` com aprovação manual entre fases | não ordena nada: só adiciona um clique por fase |
