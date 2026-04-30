variable "env" { type = string }
variable "aws_region" { type = string }

variable "vpc_id" { type = string }

variable "private_subnet_ids" {
  description = "VPC Link가 사용할 private subnet (Internal ALB와 같은 서브넷)"
  type        = list(string)
}

variable "cognito_user_pool_id" {
  description = "JWT Authorizer가 검증할 Cognito User Pool ID"
  type        = string
}

variable "cognito_user_pool_client_id" {
  description = "JWT audience 검증용 Cognito App Client ID"
  type        = string
}

variable "alb_listener_arn" {
  description = "Internal ALB의 HTTP listener ARN. 빈 문자열이면 Integration/Route가 생성되지 않음 (첫 apply 시점)"
  type        = string
  default     = ""
}
