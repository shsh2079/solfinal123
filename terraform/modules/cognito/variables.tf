variable "env" { type = string }
variable "app_name" {
  type    = string
  default = "ticketing"
}
variable "cognito_domain_prefix" { type = string }
variable "cloudfront_domain" {
  description = "CloudFront 배포 도메인 (콜백/로그아웃 URL 생성용)"
  type        = string
}
