variable "name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "CIDR da VPC, liberado no security group dos nodes para o NodePort."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets privadas onde o NLB interno e criado."
  type        = list(string)
}

variable "node_asg_names" {
  description = "Auto Scaling Groups do node group do EKS, registrados no target group."
  type        = list(string)
}

variable "node_security_group_id" {
  description = "Security group dos nodes do EKS, que recebe a regra de ingress do NodePort."
  type        = string
}

variable "node_port" {
  description = "NodePort do Service da aplicacao no EKS. Contrato com os manifestos do Kubernetes."
  type        = number

  validation {
    condition     = var.node_port >= 30000 && var.node_port <= 32767
    error_message = "node_port deve estar na faixa de NodePort do Kubernetes (30000-32767)."
  }
}

variable "health_check_protocol" {
  description = "TCP (default, funciona sem depender de rota de health no app) ou HTTP."
  type        = string
  default     = "TCP"

  validation {
    condition     = contains(["TCP", "HTTP"], var.health_check_protocol)
    error_message = "health_check_protocol deve ser TCP ou HTTP."
  }
}

variable "health_check_path" {
  description = "Rota de health check. Usada apenas quando health_check_protocol = HTTP."
  type        = string
  default     = "/"
}
