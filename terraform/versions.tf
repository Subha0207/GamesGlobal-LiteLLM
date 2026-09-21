terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.name
      Environment = "poc"
      ManagedBy   = "terraform"
    }
  }

  # Tags applied by the organization (tag policies, cost-allocation automation)
  # show up as drift, and Terraform tries to remove them. In an account with an
  # SCP that denies ec2:DeleteTags that removal is rejected and the apply fails
  # with UnauthorizedOperation. Ignoring the keys leaves them untouched.
  ignore_tags {
    keys         = var.ignore_tag_keys
    key_prefixes = var.ignore_tag_key_prefixes
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}
