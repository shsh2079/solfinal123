# ── API Gateway HTTP API ───────────────────────────────────────────
# 흐름: CloudFront → API Gateway (Cognito JWT Authorizer) → VPC Link → Internal ALB → EKS
#
# 핵심 설계:
#   1. HTTP API + JWT Authorizer = Cognito 토큰 자동 검증, 백엔드 코드 0
#   2. VPC Link v2 = Internal ALB로 직접 연결 (NLB 불필요)
#   3. Integration request_parameters = 검증된 email을 x-user-email 헤더로 매핑
#      → 백엔드는 기존 request.headers.get("x-user-email") 코드 그대로 사용
#      → 헤더 위조 차단 (API GW가 인증된 토큰의 claim만 헤더로 주입)
#   4. 첫 apply 시 alb_listener_arn=""이면 Integration/Route 생성 안 함 (chicken-and-egg)
#      두 번째 apply 시 setup-all.sh가 listener ARN을 tfvars에 박은 뒤 자동 생성

resource "aws_apigatewayv2_api" "main" {
  name          = "ticketing-http-api"
  protocol_type = "HTTP"
  description   = "Ticketing API Gateway — Cognito JWT 인증 + Internal ALB 프록시"

  cors_configuration {
    allow_origins  = ["*"]
    allow_methods  = ["GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"]
    allow_headers  = ["Authorization", "Content-Type", "x-amz-date", "x-amz-security-token"]
    expose_headers = ["*"]
    max_age        = 300
  }

  tags = { Name = "ticketing-http-api", Environment = var.env }
}

# ── Cognito JWT Authorizer ─────────────────────────────────────────
# Authorization 헤더의 JWT 토큰을 자동 검증
# - issuer가 우리 Cognito User Pool인지
# - audience(aud)가 우리 App Client ID인지
# - 서명이 Cognito 공개키와 일치하는지
# 검증 통과 시 $context.authorizer.claims.* 로 토큰 내용에 접근 가능
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-jwt-authorizer"

  jwt_configuration {
    audience = [var.cognito_user_pool_client_id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${var.cognito_user_pool_id}"
  }
}

# ── VPC Link v2 ────────────────────────────────────────────────────
# API Gateway가 private VPC 안의 Internal ALB로 트래픽을 전달하기 위한 통로
# v2는 ALB·NLB·CloudMap을 직접 지원 (v1과 달리 NLB 강제 X)
resource "aws_security_group" "vpc_link" {
  name        = "ticketing-apigw-vpclink-sg"
  description = "API Gateway VPC Link to Internal ALB"
  vpc_id      = var.vpc_id

  egress {
    description = "To Internal ALB (HTTP)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags = { Name = "ticketing-apigw-vpclink-sg", Environment = var.env }
}

resource "aws_apigatewayv2_vpc_link" "main" {
  name               = "ticketing-vpc-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = var.private_subnet_ids

  tags = { Name = "ticketing-vpc-link", Environment = var.env }
}

# ── Integration: HTTP_PROXY → Internal ALB Listener ────────────────
# alb_listener_arn이 비어있으면 (첫 apply) Integration 생성 안 함
# request_parameters로 검증된 사용자 email을 x-user-email 헤더에 강제 주입
# overwrite:로 시작하면 클라이언트가 보낸 같은 헤더를 덮어씀 → 위조 불가
resource "aws_apigatewayv2_integration" "alb" {
  count = var.alb_listener_arn != "" ? 1 : 0

  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = var.alb_listener_arn
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.main.id

  payload_format_version = "1.0"

  request_parameters = {
    "overwrite:header.x-cognito-sub"   = "$context.authorizer.claims.sub"
    "overwrite:header.x-cognito-email" = "$context.authorizer.claims.email"
    "overwrite:header.x-cognito-name"  = "$context.authorizer.claims.name"
  }

  timeout_milliseconds = 29000
}

# ── 인증 필요한 routes (JWT Authorizer 적용) ──────────────────────
# /api/* 아래 모든 메서드 → Cognito 토큰 검증 후에만 통과
resource "aws_apigatewayv2_route" "api_authenticated" {
  for_each = var.alb_listener_arn != "" ? toset([
    "ANY /api/{proxy+}",
  ]) : toset([])

  api_id             = aws_apigatewayv2_api.main.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.alb[0].id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# ── 인증 우회 routes (헬스체크, 메트릭, 공개 조회) ─────────────────
# Prometheus가 외부에서 scrape할 수 있도록, /health도 ALB healthcheck용
# 이벤트/좌석 조회는 공개 정보이므로 비로그인도 둘러볼 수 있게 인증 면제
resource "aws_apigatewayv2_route" "api_public" {
  for_each = var.alb_listener_arn != "" ? toset([
    "GET /health",
    "GET /event-metrics",
    "GET /reserv-metrics",
    "GET /worker-metrics",
    # 공개 조회: 영화
    "GET /api/read/movies",
    "GET /api/read/movies/detail/{movie_id}",
    "GET /api/read/movies/booking-bootstrap",
    "GET /api/read/movie/{movie_id}",
    # 공개 조회: 극장
    "GET /api/read/theaters",
    "GET /api/read/theaters/bootstrap",
    "GET /api/read/theaters/remain-overrides",
    "GET /api/read/theater/{theater_id}",
    # 공개 조회: 콘서트
    "GET /api/read/concerts",
    "GET /api/read/concert/{concert_id}",
    "GET /api/read/concert/{concert_id}/booking-bootstrap",
    "GET /api/read/concert/{concert_id}/booking-holds",
    # 공개: 헬스체크, 대기열, 예매상태 폴링
    "GET /api/read/health",
    "GET /api/read/waiting-room/{proxy+}",
    "GET /api/read/booking/{proxy+}",
    # 공개: 콘서트 대기열 (write-api 호스팅이지만 로그인 전 진입 허용 설계)
    # enter: 대기표 발급 / status: 대기 순번 조회 — 둘 다 로그인 전 필요
    "POST /api/write/concerts/{show_id}/waiting-room/enter",
    "GET /api/write/concerts/waiting-room/status/{queue_ref}",
    # CORS preflight
    "OPTIONS /api/{proxy+}",
  ]) : toset([])

  api_id    = aws_apigatewayv2_api.main.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.alb[0].id}"
}

# ── Default Stage with auto-deploy ─────────────────────────────────
# $default 스테이지는 base path 없이 invoke URL 그대로 사용 가능
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 10000
    throttling_rate_limit  = 5000
  }

  tags = { Name = "ticketing-http-api-default-stage", Environment = var.env }
}

# ── Internal ALB SG에서 VPC Link SG로부터의 inbound 허용 ───────────
# Internal ALB의 SG는 ALB Ingress Controller가 자동 생성하므로
# 우리는 'VPC Link SG에서 VPC 내부 0.0.0.0/16'으로 egress만 열어두면 됨
# (Internal ALB SG의 default behavior가 같은 VPC 내 HTTP를 받음)
