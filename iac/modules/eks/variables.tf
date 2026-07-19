variable "name" {
  description = "Prefixo de nomes dos recursos (ex.: servicetrack-prd)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "node_instance_types" {
  type = list(string)
}

variable "node_desired_size" {
  type = number
}

variable "node_min_size" {
  type = number
}

variable "node_max_size" {
  type = number
}

variable "lab_role_arn" {
  description = "ARN da role usada pelo cluster e pelos nodes (LabRole no ambiente educacional)."
  type        = string
}
