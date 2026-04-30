output "frontend_bucket_id" { value = aws_s3_bucket.frontend.id }
output "frontend_bucket_arn" { value = aws_s3_bucket.frontend.arn }
output "frontend_bucket_regional_domain" { value = aws_s3_bucket.frontend.bucket_regional_domain_name }
output "assets_bucket_id" { value = aws_s3_bucket.assets.id }
output "assets_bucket_arn" { value = aws_s3_bucket.assets.arn }