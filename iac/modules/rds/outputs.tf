output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = var.db_name
}

output "username" {
  value = var.db_username
}

output "password" {
  value     = random_password.db.result
  sensitive = true
}

output "jdbc_url" {
  value = "jdbc:postgresql://${aws_db_instance.this.address}:${aws_db_instance.this.port}/${var.db_name}"
}

output "security_group_id" {
  value = aws_security_group.rds.id
}
