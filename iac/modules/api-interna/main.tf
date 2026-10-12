locals {
  prefixo = "${var.name}-${var.environment}"

  abreviacao = "st-${var.environment}"

  anexos = range(var.node_asg_count)
}

resource "aws_security_group" "nlb" {
  name        = "${local.prefixo}-entrada-do-bff-nlb"
  description = "Entrada do NLB interno que a borda publica usa para alcancar o BFF"
  vpc_id      = var.vpc_id

  egress {
    description = "Alcanca os nodes do EKS na porta de NodePort do BFF"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.prefixo}-entrada-do-bff-nlb" })
}

resource "aws_security_group_rule" "nodes_recebem_do_nlb" {
  description              = "NodePort do BFF aceita trafego apenas do NLB interno"
  type                     = "ingress"
  security_group_id        = var.node_security_group_id
  from_port                = var.bff.node_port
  to_port                  = var.bff.node_port
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

resource "aws_lb_target_group" "bff" {
  name        = "${local.abreviacao}-${var.bff.nome}"
  port        = var.bff.node_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  deregistration_delay = 30

  health_check {
    protocol            = "HTTP"
    path                = var.bff.saude
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(var.tags, { Name = "${local.prefixo}-${var.bff.nome}" })
}

resource "aws_lb_listener" "bff" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.bff.node_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bff.arn
  }
}

resource "aws_autoscaling_attachment" "nodes" {
  count = length(local.anexos)

  autoscaling_group_name = var.node_asg_names[local.anexos[count.index]]
  lb_target_group_arn    = aws_lb_target_group.bff.arn
}

resource "aws_api_gateway_vpc_link" "this" {
  name        = "${local.prefixo}-entrada-do-bff"
  description = "Liga a borda publica ao NLB interno que serve o BFF"
  target_arns = [aws_lb.this.arn]

  tags = var.tags
}
