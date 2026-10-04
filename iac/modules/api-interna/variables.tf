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

variable "servicos" {
  description = "Servicos alcancaveis pela API interna. O caminho da rota e o nome: /<nome>/{proxy+}."
  type = list(object({
    nome      = string
    node_port = number
    saude     = string
  }))

  validation {
    condition     = length(var.servicos) > 0
    error_message = "A API interna precisa de pelo menos um servico; sem servico ela nao tem rota."
  }

  validation {
    condition     = length(distinct([for s in var.servicos : s.node_port])) == length(var.servicos)
    error_message = "Dois servicos com o mesmo node_port: cada um precisa do seu, porque o NLB escuta na mesma porta do NodePort."
  }

  validation {
    condition     = alltrue([for s in var.servicos : s.node_port >= 30000 && s.node_port <= 32767])
    error_message = "node_port fora da faixa que o Kubernetes aloca para NodePort, de 30000 a 32767."
  }

  validation {
    condition     = alltrue([for s in var.servicos : can(regex("^[a-z][a-z0-9-]{0,24}$", s.nome))])
    error_message = "nome do servico precisa ser minusculo, comecar com letra e ter no maximo 25 caracteres: ele entra no nome do target group, que tem teto de 32."
  }
}

variable "stage_name" {
  type    = string
  default = "interna"
}
