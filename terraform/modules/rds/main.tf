resource "aws_db_subnet_group" "main" {
  name       = "prod-rds-subnet-group"
  subnet_ids = var.subnet_ids
  tags       = { Name = "prod-rds-subnet-group", Environment = var.env }
}

# Primary (Writer) — 커밋·SQS 워커 전용. 조회 확장은 향후 Read Replica + 앱 DB_READ_REPLICA_ENABLED.
resource "aws_db_instance" "writer" {
  identifier        = "prod-ticketing-writer"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = var.writer_instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp2"

  max_allocated_storage = var.max_allocated_storage > var.allocated_storage ? var.max_allocated_storage : null

  db_name  = "ticketing"
  username = "root"
  password = var.db_password
  port     = 3306

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.security_group_id]

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = { Name = "ticketing-mysql-writer", Role = "primary", Environment = var.env }
}

# NOTE: Read Replica 는 별 변경에서 `replicate_source_db = aws_db_instance.writer.identifier` 등으로 추가 예정.
#       앱은 DB_READ_REPLICA_ENABLED + DB_READER_HOST 로 리더를 붙인 뒤 조회 부하를 Writer에서 분리한다.
