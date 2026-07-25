locals {
  present_keys = nonsensitive(toset([for k, v in var.params : k if trimspace(v) != ""]))
}

resource "aws_ssm_parameter" "this" {
  for_each = local.present_keys

  name  = "${var.name_prefix}/${each.key}"
  type  = "SecureString"
  value = var.params[each.key]
  tier  = "Standard"
  tags  = var.tags
}
