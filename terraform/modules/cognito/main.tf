resource "aws_cognito_user_pool" "main" {
  name = "${var.app_name}-user-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  schema {
    attribute_data_type = "String"
    name                = "email"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 255
    }
  }

  lambda_config {
    pre_sign_up = aws_lambda_function.auto_confirm.arn
  }

  tags = { Name = "${var.app_name}-user-pool", Environment = var.env }
}

# 회원가입 시 이메일 인증 없이 자동 확인하는 Lambda
resource "aws_lambda_function" "auto_confirm" {
  function_name    = "${var.app_name}-auto-confirm"
  runtime          = "python3.12"
  handler          = "index.handler"
  role             = aws_iam_role.lambda_auto_confirm.arn
  filename         = data.archive_file.auto_confirm.output_path
  source_code_hash = data.archive_file.auto_confirm.output_base64sha256
}

data "archive_file" "auto_confirm" {
  type        = "zip"
  output_path = "${path.module}/auto_confirm.zip"
  source {
    content  = <<-PYTHON
def handler(event, context):
    event['response']['autoConfirmUser'] = True
    event['response']['autoVerifyEmail'] = True
    return event
PYTHON
    filename = "index.py"
  }
}

resource "aws_iam_role" "lambda_auto_confirm" {
  name = "${var.app_name}-auto-confirm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_auto_confirm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_permission" "cognito_invoke" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_confirm.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.app_name}-web-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret               = false
  prevent_user_existence_errors = "ENABLED"
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]

  access_token_validity  = 1 # 1시간
  refresh_token_validity = 7 # 7일
  token_validity_units {
    access_token  = "hours"
    refresh_token = "days"
  }

  # 첫 apply 시 cloudfront_domain=""이면 localhost placeholder 사용 (cycle 차단).
  # setup-all.sh가 CF 도메인을 tfvars에 박은 뒤 재apply하면 실제 URL로 갱신된다.
  callback_urls = [var.cloudfront_domain != "" ? "https://${var.cloudfront_domain}/callback" : "http://localhost:3000/callback"]
  logout_urls   = [var.cloudfront_domain != "" ? "https://${var.cloudfront_domain}/logout" : "http://localhost:3000/logout"]

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  allowed_oauth_flows_user_pool_client = true

  supported_identity_providers = ["COGNITO"]
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.main.id
}
