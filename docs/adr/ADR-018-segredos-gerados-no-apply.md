# ADR – 018: Segredos gerados no apply, não colados em secrets do GitHub

## Data
29/07/2026

---

## Status

- Aceita

Substitui parcialmente [ADR-013](ADR-013-chaves-jwt-fora-do-git.md), que resolvia "fora do
git" mas mantinha o material colado à mão em variáveis Terraform.

---

## Contexto

O par RS256 que assina e valida os JWT era gerado à mão com `openssl` e entregue por **dois
caminhos independentes**: `lambda_extra_env` para a função de autenticação e
`app_secret_params` para a aplicação. Um par diferente em cada lado produz token emitido com
sucesso e recusado pelo backend, sem erro em nenhuma esteira — o acoplamento `A-05`.

O mesmo blob carregava as senhas das roles do banco, que **também** precisavam ser digitadas
no script que provisiona essas roles. Duas fontes para a mesma senha, sincronizadas na mão a
cada recriação de ambiente.

Como consequência, ligar a esteira ao apply exigiria colar PEM e senhas em secrets do GitHub —
segredos longevos, reusados em todas as recriações, para ambientes que duram dias.

---

## Decisão

**O que pode ser gerado, é gerado no apply. Só permanece como segredo externo o que vem de
terceiro.**

| Segredo | Antes | Agora |
|---|---|---|
| Par RS256 | `openssl` à mão, colado em duas variáveis | `tls_private_key` no `stack`, alimentando os dois consumidores no mesmo apply |
| Senhas de `app_user`, `flyway_user`, `readonly_user` | no blob, e repetidas no script de roles | `random_password` no repositório de banco, publicadas no SSM |
| Segredo do header do gateway | já era gerado | sem mudança |
| `UNSPLASH_CHAVE_ACESSO`, `RESEND_API_KEY` | dentro do blob | secrets do GitHub, uma linha cada |

O bootstrap deixa de receber um blob pronto e passa a **compor** os secrets do Kubernetes a
partir do SSM: credenciais de role vindas do repositório de banco, chaves externas e par RS256
vindos deste repositório.

`app_secret_params` continua existindo como escape para valores pontuais, mas deixa de ser o
caminho normal.

---

## Consequências

### Positivas
- O acoplamento `A-05` deixa de ser possível: um par, uma origem, um apply.
- Some a duplicação de senha entre o blob e o script de roles.
- O segredo do GitHub encolhe de um blob com PEM e senhas para duas chaves de terceiro.
- Todo segredo interno passa a ser rotacionado a cada recriação de ambiente, sem intervenção.
- O apply pela esteira deixa de exigir colar material sensível na interface do GitHub.

### Negativas
- **O material gerado continua indo para o state** (`I-16`). A melhora é qualitativa: um
  segredo que nasce com o ambiente e morre com ele é menos exposto que um colado no GitHub e
  reusado indefinidamente — mas não é o mesmo que não estar no state.
- Recriar o ambiente **invalida todos os tokens emitidos**, porque o par muda. Aceitável aqui,
  já que o ambiente inteiro é descartado junto.
- O bootstrap passa a falhar se o repositório de banco não tiver sido aplicado antes. É
  desejado — antes ele seguia em silêncio e os pods subiam sem credencial.
- Mais parâmetros no SSM para inspecionar quando algo falha.

### Impacto em ambiente efêmero
É o que torna a recriação autossuficiente: nenhum passo manual de gerar chave ou copiar senha
entre repositórios.

---

## Alternativas Consideradas

### Opção 1: Colar o blob em secrets do GitHub
Menor mudança. Rejeitada: mantém a duplicação de senha, mantém o segredo longevo e não
resolve a divergência possível entre os dois lados do par RS256.

### Opção 2: AWS Secrets Manager com rotação
Tira o material do state de vez. Não adotada agora: custo por segredo e por chamada na conta
educacional, e exigiria mudar como a aplicação lê configuração. Continua sendo a evolução
natural de `I-16`.

### Opção 3: Gerar o par fora e injetar por SSM manualmente
Rejeitada: reintroduz o passo manual a cada recriação, que é justamente o que se quer eliminar.
