locals {
  prefixo = "${var.name}-${var.environment}"

  abreviacao = "st-${var.environment}"

  servicos = { for s in var.servicos : s.nome => s }

  # O BFF entra no NLB, nao na API interna: a API interna e por onde o BFF chama os outros,
  # e quem chama o BFF e o gateway publico. Ter um alvo no mesmo NLB evita um segundo
  # balanceador e um segundo VPC Link para um unico servico.
  atras_do_nlb = var.bff == null ? local.servicos : merge(local.servicos, { (var.bff.nome) = var.bff })

  anexos = flatten([
    for s in values(local.atras_do_nlb) : [
      for i in range(var.node_asg_count) : {
        servico = s.nome
        indice  = i
      }
    ]
  ])

  rotas = merge(
    {
      for nome, s in local.servicos :
      "/${nome}" => {
        "x-amazon-apigateway-any-method" = {
          responses = {}
          "x-amazon-apigateway-integration" = {
            type                = "HTTP_PROXY"
            httpMethod          = "ANY"
            uri                 = "http://${aws_lb.this.dns_name}:${s.node_port}/"
            connectionType      = "VPC_LINK"
            connectionId        = aws_api_gateway_vpc_link.this.id
            passthroughBehavior = "when_no_match"
            timeoutInMillis     = 29000
          }
        }
      }
    },
    {
      for nome, s in local.servicos :
      "/${nome}/{proxy+}" => {
        "x-amazon-apigateway-any-method" = {
          parameters = [{
            name     = "proxy"
            in       = "path"
            required = true
            schema   = { type = "string" }
          }]
          responses = {}
          "x-amazon-apigateway-integration" = {
            type                = "HTTP_PROXY"
            httpMethod          = "ANY"
            uri                 = "http://${aws_lb.this.dns_name}:${s.node_port}/{proxy}"
            connectionType      = "VPC_LINK"
            connectionId        = aws_api_gateway_vpc_link.this.id
            passthroughBehavior = "when_no_match"
            timeoutInMillis     = 29000
            requestParameters = {
              "integration.request.path.proxy" = "method.request.path.proxy"
            }
          }
        }
      }
    },
  )

  politica = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "NegaForaDoEndpoint"
        Effect    = "Deny"
        Principal = "*"
        Action    = "execute-api:Invoke"
        Resource  = "execute-api:/*"
        Condition = {
          StringNotEquals = {
            "aws:sourceVpce" = aws_vpc_endpoint.execute_api.id
          }
        }
      },
      {
        Sid       = "PermiteDoEndpoint"
        Effect    = "Allow"
        Principal = "*"
        Action    = "execute-api:Invoke"
        Resource  = "execute-api:/*"
      },
    ]
  }

  corpo = {
    openapi = "3.0.1"
    info = {
      title       = "${local.prefixo}-interna"
      description = "Roteamento interno para os microsservicos. Alcancavel apenas pelo endpoint de interface da VPC."
      version     = "1.0"
    }
    paths                        = local.rotas
    "x-amazon-apigateway-policy" = local.politica
  }
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

resource "aws_security_group" "nlb" {
  name        = "${local.prefixo}-api-interna-nlb"
  description = "Entrada do NLB interno que serve a API interna"
  vpc_id      = var.vpc_id

  egress {
    description = "Alcanca os nodes do EKS nas portas de NodePort"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.prefixo}-api-interna-nlb" })
}

resource "aws_security_group_rule" "nodes_recebem_do_nlb" {
  for_each = local.atras_do_nlb

  description              = "NodePort de ${each.key} aceita trafego apenas do NLB interno"
  type                     = "ingress"
  security_group_id        = var.node_security_group_id
  from_port                = each.value.node_port
  to_port                  = each.value.node_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nlb.id
}

resource "aws_lb" "this" {
  name               = "${local.abreviacao}-interna"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids
  security_groups    = [aws_security_group.nlb.id]

  enable_cross_zone_load_balancing = true

  enforce_security_group_inbound_rules_on_private_link_traffic = "off"

  tags = merge(var.tags, { Name = "${local.prefixo}-api-interna" })
}

resource "aws_lb_target_group" "servico" {
  for_each = local.atras_do_nlb

  name        = "${local.abreviacao}-${each.key}"
  port        = each.value.node_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  deregistration_delay = 30

  health_check {
    protocol            = "HTTP"
    path                = each.value.saude
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(var.tags, { Name = "${local.prefixo}-${each.key}" })
}

resource "aws_lb_listener" "servico" {
  for_each = local.atras_do_nlb

  load_balancer_arn = aws_lb.this.arn
  port              = each.value.node_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.servico[each.key].arn
  }
}

resource "aws_autoscaling_attachment" "nodes" {
  count = length(local.anexos)

  autoscaling_group_name = var.node_asg_names[local.anexos[count.index].indice]
  lb_target_group_arn    = aws_lb_target_group.servico[local.anexos[count.index].servico].arn
}

resource "aws_api_gateway_vpc_link" "this" {
  name        = "${local.prefixo}-interna"
  description = "Liga a API interna ao NLB dos microsservicos"
  target_arns = [aws_lb.this.arn]

  tags = var.tags
}

resource "aws_security_group" "endpoint" {
  name        = "${local.prefixo}-execute-api"
  description = "Entrada do endpoint de interface do execute-api"
  vpc_id      = var.vpc_id

  ingress {
    description = "Chamadas de dentro da VPC ao endpoint privado do gateway"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  tags = merge(var.tags, { Name = "${local.prefixo}-execute-api" })
}

resource "aws_vpc_endpoint" "execute_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.execute-api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${local.prefixo}-execute-api" })
}

resource "aws_api_gateway_rest_api" "this" {
  name        = "${local.prefixo}-interna"
  description = "API interna dos microsservicos, sem endereco publico"
  body        = jsonencode(local.corpo)

  endpoint_configuration {
    types            = ["PRIVATE"]
    vpc_endpoint_ids = [aws_vpc_endpoint.execute_api.id]
  }

  tags = var.tags
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeploy = sha1(jsonencode(local.corpo))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name

  tags = var.tags
}
