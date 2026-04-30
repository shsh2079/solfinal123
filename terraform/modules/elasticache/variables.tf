variable "env" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }

variable "node_type" {
  type        = string
  description = "단일 노드 ElastiCache. 메모리 = 조회 캐시 워킹셋 + booking 논리 DB."
}
