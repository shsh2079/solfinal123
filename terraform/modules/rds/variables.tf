variable "env" {
  type = string
}
variable "subnet_ids" {
  type = list(string)
}
variable "security_group_id" {
  type = string
}
variable "db_password" {
  type      = string
  sensitive = true
}

variable "writer_instance_class" {
  type        = string
  description = "RDS writer (OLTP: SQS 워커 커밋). Reader 추가 시 조회는 리더로 분리 예정."
}

variable "allocated_storage" {
  type        = number
  description = "초기 할당 GB (gp2/gp3)."
}

variable "max_allocated_storage" {
  type        = number
  description = "스토리지 상한(자동 확장 상한, 0이면 비활성)."
  default     = 0
}
