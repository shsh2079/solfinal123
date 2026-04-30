output "rds_writer_endpoint" {
  value     = module.rds.writer_endpoint
  sensitive = true
}

output "rds_reader_endpoint" {
  value     = module.rds.reader_endpoint
  sensitive = true
}

output "redis_endpoint" {
  value     = module.elasticache.redis_endpoint
  sensitive = true
}

output "elasticache_primary_endpoint" {
  value     = module.elasticache.elasticache_primary_endpoint
  sensitive = true
}

output "sqs_queue_url" {
  value = module.sqs.reservation_queue_url
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_app_node_group_name" {
  description = "App EKS managed node group name."
  value       = module.eks.app_node_group_name
}

output "eks_node_role_arn" {
  description = "IAM role ARN used by EKS worker nodes."
  value       = module.eks.node_role_arn
}

output "eks_node_group_scaling_summary" {
  description = "Managed node group min, desired, and max size."
  value = {
    min     = var.eks_app_node_min_size
    desired = var.eks_app_node_desired_size
    max     = var.eks_app_node_max_size
  }
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "alb_controller_role_arn" {
  value = module.eks.alb_controller_role_arn
}

output "cluster_autoscaler_role_arn" {
  value = module.eks.cluster_autoscaler_role_arn
}

output "sqs_access_role_arn" {
  value = module.eks.sqs_access_role_arn
}

output "ai_advisor_role_arn" {
  description = "IRSA role ARN for the EKS ai-advisor CronJob."
  value       = module.ai_advisor.role_arn
}

output "ai_advisor_ecr_url" {
  description = "ai-advisor Docker image ECR URI."
  value       = aws_ecr_repository.ai_advisor.repository_url
}

output "gcp_ai_advisor_service_account_email" {
  description = "GCP service account used by ai-advisor through Workload Identity Federation."
  value       = var.enable_gcp_ai_advisor ? google_service_account.ai_advisor[0].email : null
}

output "gcp_ai_advisor_workload_identity_provider" {
  description = "GCP Workload Identity Provider resource name used by the ai-advisor credential config."
  value       = var.enable_gcp_ai_advisor ? local.gcp_ai_advisor_provider_resource_name : null
}

output "keda_operator_role_arn" {
  description = "IRSA for KEDA operator."
  value       = module.eks.keda_operator_role_arn
}

output "aws_region" {
  value = var.aws_region
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "frontend_bucket_name" {
  description = "Frontend static site bucket name."
  value       = var.enable_s3_hosting_v2_module ? module.s3_hosting_v2.frontend_bucket_name : null
}

output "frontend_website_url" {
  description = "Frontend static site website URL."
  value       = var.enable_s3_hosting_v2_module ? module.s3_hosting_v2.frontend_website_url : null
}

output "zzzzzz_url" {
  description = "Same as frontend_website_url."
  value       = var.enable_s3_hosting_v2_module ? module.s3_hosting_v2.frontend_website_url : null
}

output "frontend_cloudfront_url" {
  description = "CloudFront URL for frontend."
  value       = var.enable_s3_hosting_v2_module ? module.s3_hosting_v2.cloudfront_url : null
}

output "frontend_routing_mode" {
  description = "none | s3_website_alb_origin_js | cloudfront_alb."
  value = (
    !var.enable_s3_hosting_v2_module ? "none"
    : var.enable_cloudfront_for_frontend ? "cloudfront_alb"
    : "s3_website_alb_origin_js"
  )
}

output "zzzzz" {
  description = "Commands to run after apply."
  value       = <<-EOT

  .............................

  Check node group scaling:
  terraform output eks_node_group_scaling_summary

  export DB_USER=root
  export DB_PASSWORD=

  bash ../scripts/normalize-line-endings.sh
  bash ../k8s/scripts/apply-secrets-from-terraform.sh
  bash ../scripts/install-cluster-autoscaler.sh
  kubectl apply -k ../k8s
  bash ../k8s/scripts/sync-s3-endpoints-from-ingress.sh
  kubectl -n ${var.ticketing_namespace} patch cm ${var.ticketing_configmap_name} --type merge -p '{"data":{"DB_NAME":"ticketing"}}'
  kubectl -n ${var.ticketing_namespace} rollout restart deploy/${var.worker_deployment_name} deploy/${var.worker_deployment_name}-burst || true
  kubectl -n ${var.ticketing_namespace} rollout restart deploy/${var.read_api_deployment_name} deploy/${var.read_api_deployment_name}-burst || true
  kubectl -n ${var.ticketing_namespace} rollout restart deploy/${var.write_api_deployment_name} deploy/${var.write_api_deployment_name}-burst || true
  .............................
  EOT
}

output "cloudfront_domain" {
  value = module.cloudfront.cloudfront_domain
}

output "cognito_user_pool_id" {
  value = module.cognito.user_pool_id
}

output "cognito_client_id" {
  value = module.cognito.user_pool_client_id
}

output "cognito_user_pool_arn" {
  value = module.cognito.user_pool_arn
}

output "cognito_domain" {
  value = module.cognito.cognito_domain
}

output "api_gateway_endpoint" {
  description = "API Gateway HTTP API invoke URL used as a CloudFront origin."
  value       = module.api_gateway.api_endpoint
}

output "api_gateway_endpoint_host" {
  description = "API Gateway host without https://."
  value       = module.api_gateway.api_endpoint_host
}
