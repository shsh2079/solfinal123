resource "aws_elasticache_subnet_group" "main" {
  name       = "ticketing-redis-subnet-group"
  subnet_ids = var.subnet_ids
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "ticketing-redis"
  # AWS: description must be printable ASCII only (no CJK / control chars).
  description    = "Ticketing ElastiCache Redis single-node cache"
  engine         = "redis"
  engine_version = "7.0"
  node_type      = var.node_type
  port           = 6379

  # Single node (no replica) to minimize cost
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [var.security_group_id]

  # 스냅샷 비활성화 (프리티어 최적화)
  snapshot_retention_limit = 0

  tags = { Name = "ticketing-redis", Environment = var.env }
}
