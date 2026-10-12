variable "name" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "node_security_group_id" {
  description = "Security group dos nodes do EKS. Recebe a regra de entrada do NodePort a partir do NLB."
  type        = string
}

variable "node_asg_names" {
  description = "Nomes dos ASG do node group. Desconhecidos no plan de ambiente novo, por isso nao entram em for_each."
  type        = list(string)
}

variable "node_asg_count" {
  description = "Quantidade de ASG do node group. Precisa ser conhecida no plan para dimensionar os anexos."
  type        = number
  default     = 1
}

variable "bff" {
  description = "Unico servico atras do NLB. Nenhum outro microsservico e alcancavel por gateway (IAC-ADR-035)."
  type = object({
    nome      = string
    node_port = number
    saude     = string
  })

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,24}$", var.bff.nome))
    error_message = "nome do bff precisa ser minusculo, comecar com letra e ter no maximo 25 caracteres: ele entra no nome do target group, que tem teto de 32."
  }

  validation {
    condition     = var.bff.node_port >= 30000 && var.bff.node_port <= 32767
    error_message = "node_port do bff fora da faixa que o Kubernetes aloca para NodePort, de 30000 a 32767."
  }

  validation {
    condition     = can(regex("^/", var.bff.saude))
    error_message = "saude precisa ser um caminho absoluto, porque entra no health check HTTP do target group."
  }
}
