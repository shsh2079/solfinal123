output "bucket_name" {
  value = try(aws_s3_bucket.site[0].bucket, null)
}

output "bucket_arn" {
  value = try(aws_s3_bucket.site[0].arn, null)
}

output "website_endpoint" {
  value = try(aws_s3_bucket_website_configuration.site[0].website_endpoint, null)
}

output "website_url" {
  value = try("http://${aws_s3_bucket_website_configuration.site[0].website_endpoint}", null)
}

output "cloudfront_domain_name" {
  value = try(aws_cloudfront_distribution.site[0].domain_name, null)
}

output "cloudfront_url" {
  value = try("https://${aws_cloudfront_distribution.site[0].domain_name}", null)
}

output "website_domain" {
  value = try(aws_s3_bucket_website_configuration.site[0].website_domain, null)
}

output "regional_domain_name" {
  value = try(aws_s3_bucket.site[0].bucket_regional_domain_name, null)
}

output "cloudfront_origin_domain_name" {
  value = try(aws_s3_bucket.site[0].bucket_regional_domain_name, null)
}

output "frontend_bucket_name" {
  value = try(aws_s3_bucket.site[0].bucket, null)
}

output "frontend_website_url" {
  value = try("http://${aws_s3_bucket_website_configuration.site[0].website_endpoint}", null)
}

output "aws_region" {
  value = var.aws_region
}

