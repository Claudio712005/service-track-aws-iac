resource "aws_ssm_parameter" "this" {
  for_each = nonsensitive(toset(keys(var.params)))

  name  = "${var.name_prefix}/${each.key}"
  type  = "SecureString"
  value = var.params[each.key]
  tier  = "Standard"
  tags  = var.tags
}
