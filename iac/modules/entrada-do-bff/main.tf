locals {
  prefixo = "${var.name}-${var.environment}"

  abreviacao = "st-${var.environment}"

  # O BFF e alcancado pela borda publica, por VPC Link. O servico de verificacao de credencial
  # e alcancado pela Lambda, que roda na VPC e nao resolve ClusterIP: listener no NLB e nenhuma
  # rota em gateway (IAC-ADR-035).
  alvos = merge(
    { (var.bff.nome) = var.bff },
    var.verificacao_de_credencial == null ? {} : { (var.verificacao_de_credencial.nome) = var.verificacao_de_credencial },
  )

  anexos = flatten([
    for nome in keys(local.alvos) : [
      for i in range(var.node_asg_count) : {
        alvo   = nome
        indice = i
      }
    ]
  ])
}

resource "aws_security_group" "nlb" {
  name        = "${local.prefixo}-entrada-do-bff-nlb"
  description = "Entrada do NLB interno: borda publica -> BFF, e Lambda -> verificacao de credencial"
  vpc_id      = var.vpc_id

  egress {
    description = "Alcanca os nodes do EKS nas portas de NodePort dos alvos"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.prefixo}-entrada-do-bff-nlb" })
}

resource "aws_security_group_rule" "nodes_recebem_do_nlb" {
  for_each = local.alvos

  description              = "NodePort de ${each.key} aceita trafego apenas do NLB interno"
  type                     = "ingress"
  security_group_id        = var.node_security_group_id
  from_port                = each.value.node_port
  to_port                  = each.value.node_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nlb.id
}

resource "aws_lb" "this" {
  name               = "${local.abreviacao}-bff"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids
  security_groups    = [aws_security_group.nlb.id]

  enable_cross_zone_load_balancing = true

  enforce_security_group_inbound_rules_on_private_link_traffic = "off"

  tags = merge(var.tags, { Name = "${local.prefixo}-entrada-do-bff" })
}

resource "aws_lb_target_group" "alvo" {
  for_each = local.alvos

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

resource "aws_lb_listener" "alvo" {
  for_each = local.alvos

  load_balancer_arn = aws_lb.this.arn
  port              = each.value.node_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alvo[each.key].arn
  }
}

resource "aws_autoscaling_attachment" "nodes" {
  count = length(local.anexos)

  autoscaling_group_name = var.node_asg_names[local.anexos[count.index].indice]
  lb_target_group_arn    = aws_lb_target_group.alvo[local.anexos[count.index].alvo].arn
}

resource "aws_api_gateway_vpc_link" "this" {
  name        = "${local.prefixo}-entrada-do-bff"
  description = "Liga a borda publica ao NLB interno que serve o BFF"
  target_arns = [aws_lb.this.arn]

  tags = var.tags
}
