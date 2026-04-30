variable "aws_region" {
  description = "AWS region where the S3 bucket will be created."
  type        = string
}

variable "enabled" {
  description = "If false, no resources are created (safe toggle for environments without frontend files)."
  type        = bool
  default     = true
}

variable "bucket_prefix" {
  description = "Bucket name prefix. A random suffix will be appended to make it globally unique."
  type        = string
  default     = "ticketing-web"
}

variable "source_dir" {
  description = "Local directory that contains the static web assets to upload. Relative to the calling root module."
  type        = string
  default     = "../frontend/src"
}

variable "index_document" {
  description = "Website index document."
  type        = string
  default     = "index.html"
}

variable "error_document" {
  description = "Website error document."
  type        = string
  default     = "index.html"
}

variable "cache_control" {
  description = "Cache-Control header to apply to uploaded objects. Set null to omit."
  type        = string
  default     = "no-cache"
}

variable "tags" {
  description = "Tags applied to AWS resources."
  type        = map(string)
  default     = {}
}

variable "force_destroy" {
  description = "If true, allow Terraform to delete the bucket even if it contains objects."
  type        = bool
  default     = false
}

variable "allow_public_read" {
  description = "If true, allow public s3:GetObject for website hosting. Turn this off when switching to CloudFront + WAF (recommended)."
  type        = bool
  default     = true
}

variable "cloudfront_distribution_arn" {
  description = "If set, allow CloudFront (OAC) to read objects via bucket policy condition AWS:SourceArn."
  type        = string
  default     = null
}

variable "cloudfront_enabled" {
  description = "If true, CloudFront in front of S3 and /api/* to ALB. If false, S3 website only; api-origin.js(sync) 로 ALB URL 반영."
  type        = bool
  default     = false
}

variable "api_origin_domain_name" {
  description = "ALB DNS hostname for API (no scheme). CloudFront /api/* origin; S3-only 모드에서는 api-origin.js(sync)로 브라우저에 전달."
  type        = string
  default     = null
}

variable "cloudfront_price_class" {
  description = "CloudFront price class."
  type        = string
  default     = "PriceClass_200"
}

