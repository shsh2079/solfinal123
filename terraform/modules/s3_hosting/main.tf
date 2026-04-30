resource "random_string" "bucket_suffix" {
  count   = var.enabled ? 1 : 0
  length  = 8
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  bucket_name = var.enabled ? "${var.bucket_prefix}-${random_string.bucket_suffix[0].result}" : null

  source_dir_abs = abspath("${path.root}/${var.source_dir}")
  cloudfront_distribution_arn_effective = (
    var.cloudfront_enabled && length(aws_cloudfront_distribution.site) > 0
  ) ? aws_cloudfront_distribution.site[0].arn : var.cloudfront_distribution_arn

  mime_types = {
    html  = "text/html; charset=utf-8"
    css   = "text/css; charset=utf-8"
    js    = "application/javascript; charset=utf-8"
    json  = "application/json; charset=utf-8"
    png   = "image/png"
    jpg   = "image/jpeg"
    jpeg  = "image/jpeg"
    gif   = "image/gif"
    svg   = "image/svg+xml"
    ico   = "image/x-icon"
    txt   = "text/plain; charset=utf-8"
    woff  = "font/woff"
    woff2 = "font/woff2"
    ttf   = "font/ttf"
    otf   = "font/otf"
    map   = "application/json; charset=utf-8"
  }

  # api-origin.js 는 별도 S3 객체로 관리(내용은 Ingress sync 가 덮어씀, Terraform 은 ignore).
  static_files = var.enabled ? [for f in fileset(local.source_dir_abs, "**/*") : f if f != "api-origin.js"] : []
}

resource "aws_s3_bucket" "site" {
  count         = var.enabled ? 1 : 0
  bucket        = local.bucket_name
  force_destroy = var.force_destroy

  tags = merge(
    { Name = local.bucket_name },
    var.tags
  )
}

resource "aws_s3_bucket_ownership_controls" "site" {
  count  = var.enabled ? 1 : 0
  bucket = aws_s3_bucket.site[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  count  = var.enabled ? 1 : 0
  bucket = aws_s3_bucket.site[0].id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "site" {
  count  = var.enabled ? 1 : 0
  bucket = aws_s3_bucket.site[0].id

  index_document {
    suffix = var.index_document
  }

  error_document {
    key = var.error_document
  }
}

data "aws_iam_policy_document" "bucket_read_policy" {
  count = var.enabled ? 1 : 0

  dynamic "statement" {
    for_each = var.allow_public_read ? [1] : []
    content {
      sid     = "PublicReadGetObject"
      effect  = "Allow"
      actions = ["s3:GetObject"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      resources = ["${aws_s3_bucket.site[0].arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = local.cloudfront_distribution_arn_effective != null ? [1] : []
    content {
      sid     = "CloudFrontReadGetObject"
      effect  = "Allow"
      actions = ["s3:GetObject"]

      principals {
        type        = "Service"
        identifiers = ["cloudfront.amazonaws.com"]
      }

      resources = ["${aws_s3_bucket.site[0].arn}/*"]

      condition {
        test     = "StringEquals"
        variable = "AWS:SourceArn"
        values   = [local.cloudfront_distribution_arn_effective]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "read_policy" {
  count  = var.enabled ? 1 : 0
  bucket = aws_s3_bucket.site[0].id
  policy = data.aws_iam_policy_document.bucket_read_policy[0].json

  depends_on = [
    aws_s3_bucket_public_access_block.site,
  ]
}

resource "aws_s3_object" "static" {
  for_each = var.enabled ? { for f in local.static_files : f => f } : {}

  bucket = aws_s3_bucket.site[0].id
  key    = each.value
  source = "${local.source_dir_abs}/${each.value}"
  etag   = filemd5("${local.source_dir_abs}/${each.value}")

  content_type = lookup(
    local.mime_types,
    lower(element(concat(reverse(split(".", each.value)), [""]), 0)),
    "application/octet-stream"
  )

  cache_control = var.cache_control

  depends_on = [
    aws_s3_bucket_ownership_controls.site,
  ]
}

# S3 웹사이트 모드: 브라우저가 먼저 이 스크립트를 로드해 ALB 베이스 URL을 얻음.
# 초기 업로드는 레포의 api-origin.js, 이후 내용은 sync-s3-endpoints-from-ingress.sh 가 덮어씀 — apply 가 되돌리지 않음.
resource "aws_s3_object" "api_origin_js" {
  count = var.enabled ? 1 : 0

  bucket        = aws_s3_bucket.site[0].id
  key           = "api-origin.js"
  source        = "${local.source_dir_abs}/api-origin.js"
  etag          = filemd5("${local.source_dir_abs}/api-origin.js")
  content_type  = "application/javascript; charset=utf-8"
  cache_control = "no-store, max-age=0"

  depends_on = [
    aws_s3_bucket_ownership_controls.site,
  ]

  lifecycle {
    ignore_changes = [source, etag]
  }
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  count = var.enabled && var.cloudfront_enabled ? 1 : 0
  name  = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  count = var.enabled && var.cloudfront_enabled ? 1 : 0
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  count = var.enabled && var.cloudfront_enabled ? 1 : 0
  name  = "Managed-AllViewer"
}

data "aws_cloudfront_origin_request_policy" "cors_s3_origin" {
  count = var.enabled && var.cloudfront_enabled ? 1 : 0
  # For S3 origins, do NOT forward viewer Host header.
  name = "Managed-CORS-S3Origin"
}

resource "aws_cloudfront_origin_access_control" "site" {
  count = var.enabled && var.cloudfront_enabled ? 1 : 0

  name                              = "${local.bucket_name}-oac"
  description                       = "OAC for S3 static site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  count = var.enabled && var.cloudfront_enabled ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "ticketing-web static + api routing"
  default_root_object = var.index_document
  price_class         = var.cloudfront_price_class

  origin {
    domain_name              = aws_s3_bucket.site[0].bucket_regional_domain_name
    origin_id                = "s3-static"
    origin_access_control_id = aws_cloudfront_origin_access_control.site[0].id
  }

  origin {
    domain_name = var.api_origin_domain_name
    origin_id   = "alb-api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-static"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD", "OPTIONS"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_optimized[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.cors_s3_origin[0].id
  }

  # ALB URL 반영 파일 — 캐시 없음 (sync 후 즉시 반영).
  ordered_cache_behavior {
    path_pattern           = "/api-origin.js"
    target_origin_id       = "s3-static"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.cors_s3_origin[0].id
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "alb-api"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD", "OPTIONS"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer[0].id
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/${var.index_document}"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

