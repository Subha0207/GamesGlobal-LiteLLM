output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "postgres_endpoint" {
  value = aws_db_instance.litellm.address
}

output "valkey_endpoint" {
  value = aws_elasticache_replication_group.valkey.primary_endpoint_address
}

output "database_url" {
  description = "Connection string for LiteLLM's DATABASE_URL."
  value       = local.database_url
  sensitive   = true
}

output "litellm_master_key" {
  description = "Admin key for the LiteLLM UI and admin API."
  value       = "sk-${random_password.master_key.result}"
  sensitive   = true
}

output "litellm_salt_key" {
  description = "Encrypts provider credentials stored in Postgres. Never rotate after models exist."
  value       = "sk-${random_password.salt_key.result}"
  sensitive   = true
}

output "secrets_manager_secret_name" {
  value = aws_secretsmanager_secret.litellm.name
}

output "litellm_irsa_role_arn" {
  value = module.litellm_irsa.iam_role_arn
}

output "alb_controller_role_arn" {
  value = module.alb_controller_irsa.iam_role_arn
}

output "ingress_allowed_cidrs" {
  value = var.ingress_allowed_cidrs
}

output "acm_certificate_arn" {
  value = var.acm_certificate_arn
}
