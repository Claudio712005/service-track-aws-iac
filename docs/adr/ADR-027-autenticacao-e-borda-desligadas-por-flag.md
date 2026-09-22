# ADR-027 — Autenticação e borda desligadas por flag

- **Status:** aceito
- **Data:** 2026-09-22
- **Relacionada:** [ADR-026](ADR-026-plataforma-sem-acoplamento-a-servicos.md)

## Contexto

O `IAC-ADR-026` deixou a plataforma sem nenhum microsserviço citado, mas manteve dois
componentes herdados da Fase 3:

- a **Lambda de autenticação**, que lê `usuarios` e `usuario_roles` no RDS do
  `service-track-db-infra` — tabelas escritas pelas migrations do monólito (`A-06`);
- o **API Gateway**, cuja única rota publicada é o login dessa Lambda.

A Fase 4 exige que cada microsserviço tenha o próprio banco, e essa arquitetura de dados
ainda não foi decidida (`GLOBAL-RFC-009`). Manter a Lambda de pé obriga a manter o RDS do
monólito de pé, o que reforça exatamente o acoplamento que a fase proíbe — e faz o ambiente
custar um RDS por decisão que ainda não existe.

Além disso, ficou definido que **nada é alcançável de fora do cluster**: o consumo dos
microsserviços é interno, por outro serviço ou por um BFF que ainda não existe.

## Decisão

Duas variáveis no módulo `stack`, ambas `false` por padrão:

| Variável | Liga |
|---|---|
| `habilitar_autenticacao` | Lambda, ECR dela, par RS256, chave pública no SSM e a regra 5432 no SG do banco |
| `habilitar_borda` | API Gateway a partir do contrato EXT, e o parâmetro SSM com a URL base |

`habilitar_borda` exige `habilitar_autenticacao`, validado no `plan`: sem o login, o gateway
não teria nenhuma integração e o import do contrato falharia.

Com as duas desligadas, um `apply` entrega **rede, EKS, ArgoCD, metrics-server e a descoberta
dos microsserviços**. Nada mais. O banco do `service-track-db-infra` deixa de ser
pré-requisito da subida.

**Nada é desligado por remoção.** Módulos, contrato, scripts e ADRs continuam no repositório;
religar é trocar duas variáveis.

## Alternativas consideradas

- **Remover Lambda, gateway e contrato do repositório.** Rejeitado: a autenticação volta na
  Fase 4, com CPF, e reescrever o que já funciona é custo sem contrapartida.
- **Manter tudo ligado e conviver com o RDS do monólito.** Rejeitado: sustenta o acoplamento
  `A-06` e paga um RDS por uma decisão de arquitetura de dados que ainda não existe.
- **Publicar um authorizer sem backend, só para manter a borda de pé.** Rejeitado: um gateway
  sem integração é fachada, e fachada em demonstração vira pergunta na banca.

## Consequências

- Subir um ambiente ficou mais barato e mais curto: sem RDS, sem Lambda, sem gateway.
- **Não há autenticação em nenhum ambiente**, e nenhum serviço é acessível pela internet. O
  acesso de fora é `kubectl port-forward`, com credencial de quem executa.
- `A-06` deixa de ter efeito prático enquanto a Lambda estiver desligada. Ligar de novo sem
  antes resolver a propriedade dos dados de usuário reintroduz a dívida.
- As esteiras conferem as flags antes de rodar o bootstrap da imagem da Lambda e o contract
  test, e pulam esses passos quando não se aplicam.
- A Fase 4 precisa decidir, em `GLOBAL-RFC-009`, quem é dono da identidade — e é essa decisão
  que determina se a Lambda volta como está, vira um microsserviço de identidade, ou some.
