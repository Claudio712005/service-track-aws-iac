# Caminho privado entre o API Gateway (REST) e a aplicacao rodando no EKS.
#
# API Gateway -> VPC Link -> NLB interno -> NodePort dos nodes do EKS -> Service
#
# O NLB e criado pelo Terraform (nao pelo Kubernetes) de proposito: o VPC Link
# precisa do ARN do load balancer em tempo de apply. Se o NLB fosse criado por um
# Service type=LoadBalancer, ele so existiria depois do ArgoCD sincronizar, e o
# Terraform nao teria como referencia-lo. Ver ADR-003.
#
# O contrato com o repositorio de manifestos e a porta: o Service da aplicacao
# precisa ser type=NodePort com nodePort igual a var.node_port.

resource "aws_lb" "this" {
  name               = substr("${var.name}-app-nlb", 0, 32)
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids

  # Os nodes podem estar concentrados em uma unica AZ (em hml o node group tem
  # desired_size = 1). Sem cross-zone o no do NLB na outra AZ nao teria alvo.
  enable_cross_zone_load_balancing = true

  tags = merge(var.tags, { Name = "${var.name}-app-nlb" })
}

resource "aws_lb_target_group" "this" {
  name        = substr("${var.name}-app-tg", 0, 32)
  port        = var.node_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  # Encurta o destroy: sem isso o target group segura os nodes por 300s.
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

# Registra o ASG do node group no target group. Nodes que entram/saem por
# autoscaling sao registrados automaticamente.
resource "aws_autoscaling_attachment" "nodes" {
  for_each = toset(var.node_asg_names)

  autoscaling_group_name = each.value
  lb_target_group_arn    = aws_lb_target_group.this.arn
}

# O NLB e os ENIs do VPC Link tem IPs dentro da VPC; o trafego chega ao node com
# esses IPs como origem. Sem esta regra o health check nunca fica healthy.
resource "aws_security_group_rule" "nodes_from_nlb" {
  type              = "ingress"
  from_port         = var.node_port
  to_port           = var.node_port
  protocol          = "tcp"
  security_group_id = var.node_security_group_id
  cidr_blocks       = [var.vpc_cidr]
  description       = "NodePort da aplicacao acessivel pelo NLB do API Gateway"
}

resource "aws_api_gateway_vpc_link" "this" {
  name        = "${var.name}-vpc-link"
  description = "VPC Link do API Gateway para a aplicacao no EKS"
  target_arns = [aws_lb.this.arn]

  tags = var.tags
}
