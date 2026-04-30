output "github_actions_role_arn" { value = aws_iam_role.github_actions.arn }
output "ecr_ticketing_was_url" { value = aws_ecr_repository.ticketing_was.repository_url }
output "ecr_worker_svc_url" { value = aws_ecr_repository.worker_svc.repository_url }
output "ecr_frontend_url" { value = aws_ecr_repository.frontend.repository_url }
