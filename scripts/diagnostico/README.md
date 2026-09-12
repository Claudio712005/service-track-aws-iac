# Diagnóstico de ambiente

Scripts de leitura para descobrir o estado real de um ambiente AWS. **Nenhum altera nada** —
só consultam e comparam.

Cada um nasceu de um incidente concreto, e é isso que eles verificam: não o que a
documentação diz que deveria existir, mas o que a AWS responde agora.

```bash
export AWS_PROFILE=aws-student
scripts/diagnostico/estado-ambiente.sh hml
```

O argumento é o ambiente (`hml` ou `prd`), padrão `hml`.

| Script | Responde |
|---|---|
| `estado-ambiente.sh` | O ambiente está de pé? Borda, rede, computação e dados numa tela |
| `cadeia-de-segredos.sh` | O segredo chegou até o pod? Percorre SSM → secret do k8s → variável no processo |
| `caminho-da-borda.sh` | O gateway alcança a aplicação? Percorre integração → VPC Link → NLB → NodePort → pod |
| `fluxo-de-login.sh` | Autenticação e rotas de negócio respondem, nos dois papéis |
| `chave-de-api.sh` | Imprime URL e chave de API prontas para colar, ou exportar no shell |

## Por que cada um existe

**`cadeia-de-segredos.sh`** — um valor vazio era filtrado em silêncio: o apply terminava
verde, o parâmetro nunca chegava no SSM e a aplicação caía em `CrashLoopBackOff` minutos
depois. O script mostra em que elo a corrente arrebenta.

**`caminho-da-borda.sh`** — o gateway respondia `500` sem nada aparecer no log da aplicação,
porque a requisição não chegava nela. O script testa cada salto isoladamente, inclusive
NLB → pod de dentro da VPC, que é o que separa problema de rede de problema de aplicação.

**`fluxo-de-login.sh`** — confere o `issuer` do token contra o que a aplicação verifica.
Divergência ali faz o login funcionar e toda rota de negócio devolver `401`.

## Repetição em 403

`hml` autoriza a chave de API de forma intermitente (`I-23` em
`workspace/architecture/inconsistencias.md`). Os scripts repetem enquanto a resposta for
`403`; qualquer outro status encerra a repetição na hora, então falha real continua visível.

## A chave de API não vai para o log da esteira

`chave-de-api.sh` existe para isso. O repositório é público: o resumo de uma execução é
legível por qualquer pessoa e fica no histórico, enquanto a chave continua válida até o
ambiente ser destruído.

```bash
scripts/diagnostico/chave-de-api.sh hml          # imprime url, chave e um curl de login
eval "$(FORMATO=exportar scripts/diagnostico/chave-de-api.sh hml)"
```

## Pré-requisitos

`aws` autenticado, `kubectl` e `python3`. Credencial expirada é a causa mais comum de erro —
os scripts falham cedo e dizem isso.
