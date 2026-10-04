# service-track-api-int

Lista dos microsserviços alcançáveis pela **API interna** — a API Gateway privada que o BFF usa
para falar com os serviços (`IAC-ADR-033`).

```yaml
servicos:
  - nome: catalogo                        # vira a rota /catalogo/{proxy+}
    nodePort: 30080                       # porta do Service type=NodePort no repo do serviço
    saude: /actuator/health/readiness     # health check do target group do NLB
```

## Por que esta lista existe aqui

O `IAC-ADR-026` proibia citar microsserviço neste repositório, e com razão: nome de serviço em
módulo de plataforma acopla a plataforma ao domínio. O `IAC-ADR-033` abre **uma** exceção, e
ela está contida neste diretório: o módulo `api-interna` é genérico e recebe a lista como dado.
Serviço novo entra editando este arquivo, sem tocar em módulo.

## Contrato com o repositório do serviço

Cada entrada aqui depende de um `Service type=NodePort` no `k8s/` do serviço, na mesma porta.
As duas metades vivem em repositórios diferentes e **nada valida o par automaticamente**: porta
divergente aparece como alvo `unhealthy` no target group, não como erro de apply.

| Serviço | NodePort | Repositório |
|---|---|---|
| `catalogo` | 30080 | `service-track-catalogo` |
| `usuarios-veiculos` | 30081 | `service-track-usuarios-veiculos` |

## Esta API não é pública

Endpoint `PRIVATE`, alcançável só pelo endpoint de interface do `execute-api` dentro da VPC, com
política de recurso que nega qualquer `sourceVpce` diferente dele. Não há WAF: a AWS não associa
WebACL a API Gateway privada. Quem fica atrás do WAF é a borda pública — hoje `/autenticacao`,
amanhã o BFF.
