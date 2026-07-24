# ADR-008 — Domínio customizado opcional com base path `/service-track/v1`

- **Status:** aceito
- **Data:** 2026-07-23

## Contexto

O endpoint `execute-api` tem duas propriedades ruins para um consumidor:

- **muda a cada recriação do ambiente** — o `apiId` é gerado pela AWS, então
  `terraform destroy` + `apply` entrega uma URL nova;
- **expõe o stage no path** (`/hml`, `/prd`), acoplando o cliente ao ambiente.

O arquivo Axway removido no [ADR-004](ADR-004-fronteira-ext-terraform.md)
declarava `path: /service-track/v1`. Essa intenção — um base path estável e
versionado — não tinha equivalente na implementação inicial.

## Decisão

Suportar domínio customizado **opcional**, via a variável `custom_domain`
(default `null`), com `base_path` default `service-track/v1`.

```hcl
custom_domain = {
  domain_name      = "api.clausilva.com.br"
  hosted_zone_name = "api.clausilva.com.br"
  base_path        = "service-track/v1"
}
```

Resultado: `https://api.clausilva.com.br/service-track/v1/clientes`.

A zona pode ser referenciada por **nome** (`hosted_zone_name`) em vez de ID: o ID
não é segredo, mas ficaria preso em `*.tfvars` — que é gitignored — ou em secret
de pipeline. Por nome, a configuração fica declarativa no Git.

## Justificativa

### Por que opcional e desligado por padrão

Exige recursos que **não existem** e que custam dinheiro numa conta educacional:

| Requisito | Custo / obstáculo |
|---|---|
| Domínio registrado | existe (`clausilva.com.br`, Registro.br) |
| Route53 hosted zone | ~US$ 0,50/mês por zona, cobrado mesmo sem tráfego |
| Delegação NS no Registro.br | passo manual, uma vez |
| Certificado ACM | grátis, mas exige validação DNS na zona |

Tornar isso obrigatório quebraria o princípio de que `terraform apply` funciona
numa conta limpa sem pré-requisitos manuais.

### O conflito real: DNS externo × ambiente efêmero

O domínio do projeto (`clausilva.com.br`) está registrado no **Registro.br**, com
DNS servido pelo próprio Registro.br. Isso cria um conflito que não é óbvio:

`aws_api_gateway_domain_name` publica um alvo regional
(`d-<aleatório>.execute-api.us-east-1.amazonaws.com`). Esse `d-` **é gerado a cada
criação do recurso**. Como o ambiente é destruído e recriado com frequência, o
alvo muda junto — e com o DNS fora da AWS isso significaria **editar o registro no
painel do Registro.br a cada recriação**. Exatamente o passo manual que o
[ADR-006](ADR-006-ambientes-efemeros-e-conta-educacional.md) proíbe.

O mesmo vale para o certificado: se o ACM for recriado, o CNAME de validação muda.

### Decisão: separar o que é persistente do que é efêmero

A hosted zone é **infraestrutura persistente**, não do ambiente:

```
iac/bootstrap/dns/     zona api.clausilva.com.br   -> aplicado UMA vez, nunca destruído
                                                      state: servicetrack/bootstrap-dns
iac/environments/hml/  cert + domain + alias       -> destruído e recriado à vontade
iac/environments/prd/  cert + domain + alias          state: servicetrack/{hml,prd}
```

No Registro.br delega-se **uma única vez** o subdomínio `api.clausilva.com.br`
para os 4 name servers da zona Route53. A partir daí:

- o alias A e o CNAME de validação do ACM vivem **dentro** da zona;
- `terraform destroy` + `apply` refaz os dois automaticamente;
- o Registro.br nunca mais é tocado, mesmo com o `d-` mudando.

Esse padrão já existe no repositório: o bucket de state
(`servicetrack-tfstate-...`) também sobrevive às sessões de laboratório. A zona
entra na mesma categoria.

Endereçamento resultante:

| Ambiente | Domínio |
|---|---|
| PRD | `api.clausilva.com.br` (ápice da zona) |
| HML | **nenhum** — só o endpoint `execute-api` |

**HML ficou de fora por decisão de custo.** O domínio em si não é o gasto
relevante, mas HML foi enxugado para liberar orçamento para observabilidade
(Datadog), e um domínio ali só acrescentaria um certificado ACM e um alias sem
benefício: ninguém integra com HML por URL estável. A variável `custom_domain`
**não existe** em `environments/hml` — habilitar exige mudança de código
revisável, não um `-var` de linha de comando.

Delega-se o subdomínio, não o ápice. O `clausilva.com.br` tem registros MX, SPF
(`v=spf1 include:amazonses.com`) e DKIM do Resend/SES em uso: delegar o ápice ao
Route53 **derrubaria o e-mail do domínio**.

### Por que dois modos de certificado

```
hosted_zone_name / hosted_zone_id  -> emite via ACM com validacao DNS + cria alias A
certificate_arn                    -> reusa certificado existente
```

Uma `validation` na variável rejeita o caso em que nenhum dos dois é informado,
com mensagem explicando o que falta — falha no `plan`, não no meio do `apply`.

Se só `certificate_arn` for informado (sem zona), o domínio e o base path mapping
são criados mas o registro DNS não: o output `api_custom_domain_target` entrega o
alvo regional para apontar num DNS externo — **com a ressalva de que esse alvo
muda a cada recriação**, o que só é aceitável para ambiente estável.

### Por que base path multinível

`service-track/v1` tem duas partes. O API Gateway REST passou a aceitar base path
mapping multinível em 2023; antes, só um segmento era permitido. É isso que
permite recuperar literalmente o path do arquivo Axway em vez de achatá-lo para
`servicetrack-v1`.

> **Risco:** se a conta ou a região não suportar mapeamento multinível, o apply
> falha nesse recurso. Contorno sem mudar código: `base_path = "v1"`.

### Endpoint regional, não edge

Coerente com `endpoint_configuration REGIONAL` já usado no REST API. Edge-optimized
exigiria certificado em `us-east-1` e CloudFront, sem ganho para uso acadêmico
concentrado numa região.

## Efeito no contrato

O `openApi.yaml` ganhou um **segundo** entry em `servers`, documentando as duas
formas de exposição:

```yaml
servers:
- url: https://{apiId}.execute-api.{region}.amazonaws.com/{stage}
- url: https://{domain}/{basePath}
```

Nenhuma URL concreta de HML ou PRD foi hardcodada — continuam sendo variáveis de
servidor com default. `servers` é ignorado na importação; existe para o
consumidor.

## Consequências

- Com domínio ligado, a URL deixa de mudar entre recriações — o principal ganho.
- O stage some do path visível ao cliente; qual ambiente responde passa a ser
  decidido pelo domínio — e HML segue no `execute-api`.
- O endpoint `execute-api` continua funcionando em paralelo. Fechá-lo exigiria uma
  resource policy — não feito, para não travar o contract test da pipeline.
- `terraform destroy` remove o domínio e o certificado emitido. A **zona não**:
  ela vive em outro state. Destruí-la por engano custa uma nova delegação no
  Registro.br e horas de propagação.
- A emissão do certificado ACM acrescenta alguns minutos ao primeiro apply de cada
  recriação (validação DNS).
- Depende de a `LabRole` permitir Route53 e ACM. Se não permitir, `custom_domain`
  fica `null` e a API responde só pelo `execute-api`.
- A delegação NS no Registro.br **não tem API pública**, então é o único passo
  manual da arquitetura. Ficou isolado em duas esteiras próprias
  (`dns-bootstrap.yml` e `dns-publish.yml`) e acontece uma única vez; a esteira
  principal detecta a delegação sozinha (`custom_domain: auto`) e nunca depende
  dela para subir PRD.
