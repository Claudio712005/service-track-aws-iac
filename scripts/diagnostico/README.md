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
| `estado-ambiente.sh` | O ambiente está de pé? Borda, pods dos microsserviços, Applications do ArgoCD, Lambda e banco numa tela |
| `fluxo-de-login.sh` | A autenticação responde nos dois papéis e emite o `issuer` esperado |
| `chave-de-api.sh` | Imprime URL e chave de API prontas para colar, ou exportar no shell |

## Por que cada um existe

**`fluxo-de-login.sh`** — confere o `issuer` do token contra o que os microsserviços
verificam. Divergência ali faz o login funcionar e toda rota de negócio devolver `401`.

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
