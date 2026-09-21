variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "litellm-poc"
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the POC VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "kubernetes_version" {
  description = <<-DESC
    EKS control plane version. AWS drops old versions over time, and an
    unsupported one fails at node group creation with "Requested AMI for this
    version is not supported". Check what is currently offered with:
      aws eks describe-cluster-versions --query 'clusterVersions[].clusterVersion'
  DESC
  type        = string
  default     = "1.33"
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_desired_size" {
  description = "Desired node count."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 4
}

variable "postgres_version" {
  description = <<-DESC
    RDS PostgreSQL version. Deliberately the major version only: RDS then picks
    the latest supported minor, so this cannot break when AWS retires a specific
    minor like 16.4. Pin a full version only if you need an exact minor.
  DESC
  type        = string
  default     = "16"
}

variable "postgres_instance_class" {
  description = "RDS instance class. db.t4g.medium is the smallest sane class for LiteLLM spend writes."
  type        = string
  default     = "db.t4g.medium"
}

variable "postgres_db_name" {
  description = "Database name LiteLLM connects to."
  type        = string
  default     = "litellm"
}

variable "postgres_username" {
  description = "Master username for RDS."
  type        = string
  default     = "litellm"
}

variable "valkey_node_type" {
  description = "ElastiCache node type for Valkey."
  type        = string
  default     = "cache.t4g.micro"
}

variable "valkey_version" {
  description = "Valkey engine version."
  type        = string
  default     = "7.2"
}

variable "gitops_repo_url" {
  description = "HTTPS or SSH URL of the git repository ArgoCD reconciles from."
  type        = string
  default     = ""
}

variable "gemini_api_key" {
  description = <<-DESC
    Google AI Studio key, stored in Secrets Manager and pulled into the cluster
    by External Secrets Operator. Under GitOps this replaces .env as the source
    of truth - the deploy scripts no longer write provider keys into the
    Kubernetes Secret.
  DESC
  type        = string
  sensitive   = true
  default     = ""
}

variable "huggingface_api_key" {
  description = "Hugging Face token with the 'Make calls to Inference Providers' permission."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ingress_allowed_cidrs" {
  description = "CIDRs allowed to reach the LiteLLM ALB (proxy + UI). Lock this to your office/VPN range for the POC."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "acm_certificate_arn" {
  description = "Optional ACM cert ARN. When set, the ALB listens on HTTPS/443 and redirects HTTP."
  type        = string
  default     = ""
}

variable "ignore_tag_keys" {
  description = <<-DESC
    Exact tag keys Terraform must never add, change or remove. Populate this
    with the keys your organization applies automatically - list them with:
      aws ec2 describe-tags --filters "Name=resource-id,Values=<vpc-id>"
  DESC
  type        = list(string)
  default     = []
}

variable "ignore_tag_key_prefixes" {
  description = "Tag key prefixes Terraform must leave alone, e.g. [\"presidio:\", \"aws:\"]."
  type        = list(string)
  default     = []
}
