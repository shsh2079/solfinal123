output "writer_endpoint" {
  value     = aws_db_instance.writer.address
  sensitive = true
}
output "reader_endpoint" {
  value     = null
  sensitive = true
}
output "db_port" {
  value = aws_db_instance.writer.port
}
