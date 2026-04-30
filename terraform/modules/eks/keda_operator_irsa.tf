# KEDA operator Pod 가 SQS GetQueueAttributes 로 스케일 메트릭 조회 (ScaledObject aws-sqs-queue).
# TriggerAuthentication identityOwner=keda 일 때 이 역할이 사용됨 (KEDA operator SA).
# (workload sqs-access-sa IRSA 는 워커 Pod 용이며, KEDA operator 프로세스에서는 동작하지 않는 경우가 많음)

resource "aws_iam_role" "keda_operator" {
  name = "${local.name_prefix}-keda-operator-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer}:sub" = "system:serviceaccount:keda:keda-operator"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "keda_operator_sqs_read" {
  name = "${local.name_prefix}-keda-operator-sqs-read"
  role = aws_iam_role.keda_operator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
      ]
      Resource = var.sqs_queue_arns
    }]
  })
}
