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

variable "image_tag_mutability" {
  type    = string
  default = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability deve ser MUTABLE ou IMMUTABLE."
  }
}

variable "max_image_count" {
  type    = number
  default = 10
}

variable "untagged_expire_days" {
  type    = number
  default = 7
}
