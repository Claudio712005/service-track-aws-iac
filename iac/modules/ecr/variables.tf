variable "repository_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "scan_on_push" {
  type    = bool
  default = true
}
