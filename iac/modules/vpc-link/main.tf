resource "aws_security_group" "nlb" {
  name        = "${var.name}-app-nlb-sg"
  description = "Entrada do NLB que serve o API Gateway"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-app-nlb-sg" })
}

resource "aws_security_group_rule" "nlb_from_vpc" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.nlb.id
  cidr_blocks       = [var.vpc_cidr]
  description       = "ENIs do VPC Link. Nao sao referenciaveis por security group, entao a origem e a VPC"
}

resource "aws_security_group_rule" "nlb_para_nodes" {
  type                     = "egress"
  from_port                = var.node_port
  to_port                  = var.node_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.nlb.id
  source_security_group_id = var.node_security_group_id
  description              = "NodePort da aplicacao"
}

resource "aws_lb" "this" {
  name               = substr("${var.name}-app-nlb", 0, 32)
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids
  security_groups    = [aws_security_group.nlb.id]

  enable_cross_zone_load_balancing = true

  tags = merge(var.tags, { Name = "${var.name}-app-nlb" })
}

resource "aws_lb_target_group" "this" {
  name        = substr("${var.name}-app-tg", 0, 32)
  port        = var.node_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  preserve_client_ip = false

  deregistration_delay = 30

  health_check {
    protocol            = var.health_check_protocol
    port                = "traffic-port"
    path                = var.health_check_protocol == "HTTP" ? var.health_check_path : null
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = var.tags
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_autoscaling_attachment" "nodes" {
  for_each = toset(var.node_asg_names)

  autoscaling_group_name = each.value
  lb_target_group_arn    = aws_lb_target_group.this.arn
}

resource "aws_security_group_rule" "nodes_from_nlb" {
  type                     = "ingress"
  from_port                = var.node_port
  to_port                  = var.node_port
  protocol                 = "tcp"
  security_group_id        = var.node_security_group_id
  source_security_group_id = aws_security_group.nlb.id
  description              = "NodePort da aplicacao, apenas a partir do NLB do API Gateway"
}

resource "aws_api_gateway_vpc_link" "this" {
  name        = "${var.name}-vpc-link"
  description = "VPC Link do API Gateway para a aplicacao no EKS"
  target_arns = [aws_lb.this.arn]

  tags = var.tags
}
