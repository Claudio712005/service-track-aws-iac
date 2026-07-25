variable "name_prefix" {
  type = string
}

variable "params" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
