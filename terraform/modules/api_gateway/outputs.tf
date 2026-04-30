output "api_endpoint" {
  description = "API Gateway invoke URL (예: https://abc123.execute-api.ap-northeast-2.amazonaws.com)"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "api_id" {
  value = aws_apigatewayv2_api.main.id
}

output "api_endpoint_host" {
  description = "도메인 부분만 (CloudFront origin domain_name용)"
  value       = replace(aws_apigatewayv2_api.main.api_endpoint, "https://", "")
}

output "vpc_link_id" {
  value = aws_apigatewayv2_vpc_link.main.id
}
