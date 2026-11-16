# Collection Postman da plataforma

`servicetrack.postman_collection.json` exercita a plataforma inteira: a borda pública (Lambda de
autenticação e BFF), o ciclo da ordem de serviço, a saga de estoque e a cobrança no Mercado Pago.

O arquivo versionado é um **modelo**: `baseUrl` e `apiKey` vão vazios, porque mudam a cada
recriação do ambiente e chave de API não entra em git.

## Uso

```bash
bash scripts/atualizar-collection-postman.sh hml          # consumidor web
bash scripts/atualizar-collection-postman.sh hml mobile   # outra chave
bash scripts/abrir-port-forwards.sh hml                   # terminal que fica aberto
```

O primeiro comando só exige **estar logado na AWS** (o mesmo `aws sts get-caller-identity` das
outras esteiras). Ele lê a URL em `/servicetrack/<env>/api/base-url` no SSM e a chave do consumidor
no API Gateway, e grava `docs/postman/servicetrack-<env>.gerado.postman_collection.json` — ignorado
pelo git. Importe esse arquivo e use com **No Environment**: os valores ficam na aba *Variables* da
collection.

O port-forward exige `kubectl` e só é necessário para as rotas marcadas **[interno]**.

## Pastas

| Pasta | Conteúdo |
|---|---|
| **Mecânico** | login, consultas (clientes, mecânicos, catálogo, saldo) e o ciclo da OS: abrir, diagnóstico, incluir e remover itens, orçamento, concluir serviço, finalizar, entregar, cancelar |
| **Cliente** | login, minhas OS, aprovar ou reprovar orçamento, pagar por Pix ou boleto, consultar e reconciliar a cobrança |
| **Saga** | `1. Fluxo completo` e `2. Falha e compensação`, para rodar inteiros pelo Collection Runner; `3. Operações` para acompanhar e retentar sagas |

As pastas por persona operam sobre a OS guardada em `ordemId`. Os logins guardam `tokenMecanico` e
`tokenCliente`; abrir a OS, incluir o serviço, gerar o orçamento e pagar guardam os identificadores
que os passos seguintes usam.

## Rotas [interno]

Diagnóstico, itens, orçamento, finalização, entrega, cancelamento, reprovação e cobrança ainda não
são expostos pelo BFF. Essas requisições vão direto ao serviço de ordens (`ordensUrl`,
`localhost:18083`) e ao checkout (`checkoutUrl`, `localhost:18084`) pelo port-forward. Quando o
BFF passar a expô-las, basta trocar a URL da requisição para `{{baseUrl}}/bff/...`.

## Variáveis

| Variável | Origem |
|---|---|
| `baseUrl`, `apiKey` | preenchidas pelo script, a cada ambiente |
| `ordensUrl`, `checkoutUrl` | portas do port-forward |
| `cpfMecanico`, `cpfCliente`, `senha`, `clienteId`, `mecanicoId`, `veiculoId` | usuários e veículo do seed do `usuarios-veiculos` |
| `servicoId`, `insumoId`, `insumoSemSaldoId` | seed do `catalogo`; o último tem saldo zero de propósito, para a compensação |
| `valorServico`, `quantidadeInsumo`, `custoMaoDeObra`, `custoInsumos` | valores do orçamento de exemplo |
| `esperaSagaMs` | espera antes de consultar a saga, o tempo de ida e volta pelo Kafka |
| `tokenMecanico`, `tokenCliente`, `ordemId`, `itemServicoId`, `valorOrcamento`, `cobrancaId`, `ordemFalhaId` | preenchidas pelos scripts das requisições |
