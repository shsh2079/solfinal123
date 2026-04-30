terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

resource "aws_wafv2_web_acl" "main" {
  name        = "ticketing-waf"
  scope       = "CLOUDFRONT"
  description = "Ticketing system WAF"

  default_action {
    allow {}
  }

  # AWS 관리형 규칙: 공통 위협
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # IP Rate Limiting: 5분에 2000요청 초과 차단
  # (SPA 초기 로드 1 페이지 = 리소스 수십 개 + API 호출 여러 건이 묶여 발사되므로
  #  100/분 은 일반 시연 중 정상 유저도 쉽게 돌파. WAF rate 는 최소 윈도우가 5분)
  rule {
    name     = "RateLimitRule"
    priority = 2
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit"
      sampled_requests_enabled   = true
    }
  }

  # SQL Injection 차단
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "TicketingWAF"
    sampled_requests_enabled   = true
  }

  tags = { Purpose = "ticketing" }
}
