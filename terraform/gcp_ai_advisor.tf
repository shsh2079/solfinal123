data "google_project" "ai_advisor" {
  count      = var.enable_gcp_ai_advisor ? 1 : 0
  project_id = var.gcp_project_id
}

locals {
  gcp_ai_advisor_enabled = var.enable_gcp_ai_advisor

  gcp_ai_advisor_required_services = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "sts.googleapis.com",
  ])

  gcp_ai_advisor_sa_email = (
    local.gcp_ai_advisor_enabled
    ? "${var.gcp_ai_advisor_service_account_id}@${var.gcp_project_id}.iam.gserviceaccount.com"
    : ""
  )

  gcp_ai_advisor_pool_resource_name = (
    local.gcp_ai_advisor_enabled
    ? "projects/${data.google_project.ai_advisor[0].number}/locations/global/workloadIdentityPools/${var.gcp_workload_identity_pool_id}"
    : ""
  )

  gcp_ai_advisor_provider_resource_name = (
    local.gcp_ai_advisor_enabled
    ? "${local.gcp_ai_advisor_pool_resource_name}/providers/${var.gcp_workload_identity_provider_id}"
    : ""
  )

  gcp_ai_advisor_credential_config = (
    local.gcp_ai_advisor_enabled
    ? jsonencode({
      type                              = "external_account"
      audience                          = "//iam.googleapis.com/${local.gcp_ai_advisor_provider_resource_name}"
      subject_token_type                = "urn:ietf:params:aws:token-type:aws4_request"
      token_url                         = "https://sts.googleapis.com/v1/token"
      service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${local.gcp_ai_advisor_sa_email}:generateAccessToken"
      credential_source = {
        environment_id                 = "aws1"
        region_url                     = "http://169.254.169.254/latest/meta-data/placement/availability-zone"
        url                            = "http://169.254.169.254/latest/meta-data/iam/security-credentials"
        regional_cred_verification_url = "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15"
        imdsv2_session_token_url       = "http://169.254.169.254/latest/api/token"
      }
    })
    : ""
  )
}

resource "google_project_service" "ai_advisor" {
  for_each = var.enable_gcp_ai_advisor ? local.gcp_ai_advisor_required_services : toset([])

  project            = var.gcp_project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_iam_workload_identity_pool" "ai_advisor" {
  count = var.enable_gcp_ai_advisor ? 1 : 0

  project                   = var.gcp_project_id
  workload_identity_pool_id = var.gcp_workload_identity_pool_id
  display_name              = "EKS AI Advisor Pool"
  description               = "Allows the EKS ai-advisor IRSA role to authenticate to GCP without service account keys."
  disabled                  = false

  depends_on = [google_project_service.ai_advisor]
}

resource "google_iam_workload_identity_pool_provider" "ai_advisor_aws" {
  count = var.enable_gcp_ai_advisor ? 1 : 0

  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.ai_advisor[0].workload_identity_pool_id
  workload_identity_pool_provider_id = var.gcp_workload_identity_provider_id
  display_name                       = "EKS AWS Provider"
  description                        = "Trusts AWS STS identities from the ticketing AWS account."
  disabled                           = false

  aws {
    account_id = data.aws_caller_identity.current.account_id
  }

  attribute_mapping = {
    "google.subject"     = "assertion.arn"
    "attribute.aws_role" = "assertion.arn.extract('assumed-role/{role}/')"
  }
}

resource "google_service_account" "ai_advisor" {
  count = var.enable_gcp_ai_advisor ? 1 : 0

  project      = var.gcp_project_id
  account_id   = var.gcp_ai_advisor_service_account_id
  display_name = "EKS AI Advisor (WIF)"

  depends_on = [google_project_service.ai_advisor]
}

resource "google_project_iam_member" "ai_advisor_log_writer" {
  count = var.enable_gcp_ai_advisor ? 1 : 0

  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.ai_advisor[0].email}"
}

resource "google_service_account_iam_member" "ai_advisor_irsa_wif" {
  count = var.enable_gcp_ai_advisor ? 1 : 0

  service_account_id = google_service_account.ai_advisor[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.gcp_ai_advisor_pool_resource_name}/attribute.aws_role/${module.ai_advisor.role_name}"
}

resource "google_service_account_iam_member" "ai_advisor_node_wif" {
  count = var.enable_gcp_ai_advisor ? 1 : 0

  service_account_id = google_service_account.ai_advisor[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.gcp_ai_advisor_pool_resource_name}/attribute.aws_role/${module.eks.node_role_name}"
}

resource "kubernetes_service_account_v1" "ai_advisor" {
  count = var.enable_gcp_ai_advisor ? 1 : 0

  metadata {
    name      = "ai-advisor-sa"
    namespace = var.ticketing_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = module.ai_advisor.role_arn
    }
  }

  depends_on = [
    module.ai_advisor,
    null_resource.k8s_bootstrap_after_apply,
  ]
}

resource "kubernetes_config_map_v1" "gcp_credential_config" {
  count = var.enable_gcp_ai_advisor ? 1 : 0

  metadata {
    name      = "gcp-credential-config"
    namespace = var.ticketing_namespace
  }

  data = {
    "config.json" = local.gcp_ai_advisor_credential_config
  }

  depends_on = [
    google_service_account_iam_member.ai_advisor_irsa_wif,
    google_service_account_iam_member.ai_advisor_node_wif,
    null_resource.k8s_bootstrap_after_apply,
  ]
}

resource "kubernetes_secret_v1" "ai_advisor" {
  count = var.enable_gcp_ai_advisor && var.create_ai_advisor_secret ? 1 : 0

  metadata {
    name      = "ai-advisor-secrets"
    namespace = var.ticketing_namespace
  }

  data = {
    GEMINI_API_KEY    = var.gemini_api_key
    SLACK_WEBHOOK_URL = var.slack_webhook_url
  }

  type = "Opaque"

  depends_on = [null_resource.k8s_bootstrap_after_apply]
}
