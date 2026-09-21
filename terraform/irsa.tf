################################################################################
# EBS CSI driver - lets the cluster provision gp3 volumes
################################################################################
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${var.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

################################################################################
# AWS Load Balancer Controller - provisions the ALB that exposes the LiteLLM UI
################################################################################
module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                              = "${var.name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

################################################################################
# LiteLLM pod role - the proxy's own identity.
# The providers in providers/models.yaml authenticate with their own API keys
# from the Kubernetes Secret, so the only AWS permission the pods need is read
# access to their own Secrets Manager secret.
################################################################################
data "aws_iam_policy_document" "litellm_runtime" {
  statement {
    sid       = "ReadOwnSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.litellm.arn]
  }
}

resource "aws_iam_policy" "litellm_runtime" {
  name        = "${var.name}-runtime"
  description = "Runtime permissions for the LiteLLM proxy pods"
  policy      = data.aws_iam_policy_document.litellm_runtime.json
}

module "litellm_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.name}-runtime"

  role_policy_arns = {
    runtime = aws_iam_policy.litellm_runtime.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["litellm:litellm"]
    }
  }
}

################################################################################
# Generated credentials, kept in Secrets Manager as the source of truth
################################################################################
resource "random_password" "master_key" {
  length  = 32
  special = false
}

resource "random_password" "salt_key" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "litellm" {
  name                    = "${var.name}/proxy"
  description             = "LiteLLM master key, salt key and datastore connection strings"
  recovery_window_in_days = 0 # POC: allow immediate delete/recreate
}

resource "aws_secretsmanager_secret_version" "litellm" {
  secret_id = aws_secretsmanager_secret.litellm.id
  secret_string = jsonencode({
    LITELLM_MASTER_KEY = "sk-${random_password.master_key.result}"
    LITELLM_SALT_KEY   = "sk-${random_password.salt_key.result}"
    DATABASE_URL       = local.database_url
    REDIS_HOST         = aws_elasticache_replication_group.valkey.primary_endpoint_address
    REDIS_PORT         = "6379"
  })
}

locals {
  database_url = format(
    "postgresql://%s:%s@%s:%s/%s?sslmode=require",
    var.postgres_username,
    random_password.postgres.result,
    aws_db_instance.litellm.address,
    aws_db_instance.litellm.port,
    var.postgres_db_name,
  )
}
