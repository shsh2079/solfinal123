variable "env" { type = string }
variable "frontend_bucket_id" { type = string }
variable "frontend_bucket_arn" { type = string }
variable "frontend_domain" { type = string }
variable "waf_acl_arn" { type = string }

variable "api_gateway_endpoint_host" {
  description = "API Gateway invoke 도메인 (예: abc123.execute-api.ap-northeast-2.amazonaws.com). 빈 문자열이면 API origin이 생성되지 않습니다."
  type        = string
  default     = ""
}
