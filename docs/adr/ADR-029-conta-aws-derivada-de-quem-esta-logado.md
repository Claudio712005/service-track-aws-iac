# IAC-ADR-029: nenhum identificador de conta AWS escrito no código

## Data
29/09/2026

## Status
Aceita.

---

## Contexto

O nome do bucket de state é `servicetrack-tfstate-<conta>` — o identificador da conta entra no
nome porque nome de bucket S3 é global e precisa ser único. Até aqui, esse nome estava escrito
como literal em onze arquivos, espalhados por três repositórios:

| Repositório | Onde |
|---|---|
| `aws-iac` | `backend "s3"` de quatro `versions.tf`, `default` de `state_bucket` no módulo `stack`, verificação de pré-requisito em `terraform.yml`, guarda `ESPERADO` em `bootstrap-tfstate.sh` |
| `service-track-catalogo` | `infra/terraform/backend/{hml,prd}.hcl`, `newName` do ECR nos overlays de `hml` e `prd` |
| `service-track-db-infra` | dois `versions.tf` e dois `variables.tf` |

A conta é de laboratório educacional e **muda**. Já mudou: o código nasceu em `821146464895` e
o laboratório passou a entregar outra conta. Nesse momento, o custo de começar a trabalhar
passou a ser um pull request mecânico em três repositórios, antes de qualquer `terraform init`.
Um ambiente que é recriado toda semana não pode ter isso no caminho crítico.

O `bootstrap-tfstate.sh` já sabia disso: ele **lia a conta real** com
`aws sts get-caller-identity` e montava o nome do bucket a partir dela. O literal `ESPERADO`
existia só como trava — se a conta divergisse, ele parava e imprimia o `sed` a ser rodado. A
trava estava certa em detectar o problema e errada em exigir commit para resolvê-lo.

## Decisão

**O identificador da conta não aparece em nenhum arquivo versionado.** Ele é sempre derivado de
quem está autenticado no momento da execução.

No Terraform:

- O bloco `backend "s3"` dos quatro `versions.tf` fica **parcial**: `key`, `region`, `encrypt` e
  `use_lockfile` continuam no arquivo; `bucket` sai e chega por `-backend-config` no `init`.
- O módulo `stack` deriva o bucket de `data.aws_caller_identity`, usado para ler o state da rede.
  A variável `state_bucket` continua existindo, com `default` vazio, apenas como escotilha para
  apontar um bucket diferente do da conta corrente.

Na esteira:

- `scripts/bootstrap-tfstate.sh` perde a guarda `ESPERADO` e passa a exportar
  `BUCKET_DE_STATE` para os passos seguintes quando roda dentro do GitHub Actions. Ele continua
  sendo o único lugar que constrói o nome.
- Os dois `terraform init` e a verificação do state da rede usam `$BUCKET_DE_STATE`.

No uso local:

- `scripts/tf-init.sh <rede|stack> <hml|prd>` faz o `init` com o `-backend-config` correto.
  Chamar `terraform init` direto passa a falhar pedindo o `bucket`, o que é o comportamento
  desejado: falha explícita em vez de apontar para o bucket errado.

## Consequências

- **Trocar de laboratório deixa de exigir alteração de código.** Renovar as credenciais e rodar
  a esteira é suficiente; o bucket é criado na conta nova pelo próprio bootstrap.
- **O `init` ganhou um pré-requisito**: credencial AWS válida antes do `init`, porque o nome do
  bucket vem do `sts`. Na esteira isso já era verdade — o passo de credenciais vem antes. No uso
  local, é o que o `tf-init.sh` resolve.
- **`terraform init` sem argumento não funciona mais**, de propósito. Quem chamar direto recebe
  erro de campo obrigatório ausente, não um state errado criado em silêncio.
- **O state antigo continua onde está.** Nada é migrado: o bucket da conta anterior segue
  existindo naquela conta, inacessível e irrelevante. Ambiente em conta nova nasce do zero, que
  é o modo normal de operação aqui.
- A escotilha `state_bucket` permite ler o state de rede de outro bucket sem mudar código, caso
  algum dia haja mais de uma conta em jogo.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Manter a guarda e rodar o `sed` a cada troca | é exatamente o custo que se quer eliminar; onze arquivos, três repositórios, antes de poder trabalhar |
| Nome de bucket sem o identificador da conta | nome de bucket S3 é global: colide com qualquer outra conta que use o mesmo nome |
| Guardar o identificador num secret do GitHub | resolve a esteira e não resolve o uso local, e ainda precisa ser atualizado a cada troca — só muda o lugar do trabalho manual |
| Backend dinâmico por workspace | workspaces não parametrizam o nome do bucket, apenas a chave |
| `terragrunt` gerando o backend | dependência nova para um problema que `-backend-config` resolve |
