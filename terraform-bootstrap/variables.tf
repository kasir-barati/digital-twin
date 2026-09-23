variable "project_name" {
  description = "Name prefix for all resources"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens only"
  }
}

variable "environment" {
  description = "Environment name (dev, test, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, prod."
  }
}

variable "aws_region" {
  description = "AWS region for the default provider (main stack resources)"
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use. Required so Terraform never silently falls back to the default profile or credentials in ~/.aws — you must explicitly name the profile to provision against."
  type        = string

  validation {
    condition     = length(trimspace(var.aws_profile)) > 0
    error_message = "aws_profile must be set to an explicit AWS CLI profile name (see ~/.aws/config). This prevents accidentally provisioning against the wrong AWS account."
  }
}

variable "github_repository" {
  description = "GitHub repository in format 'owner/repo'"
  type        = string
}

variable "github_oidc_sub_prefix" {
  description = "Prefix of the OIDC token's sub claim. With GitHub's immutable subject enabled it carries owner/repo IDs, e.g. 'repo:owner@123/repo@456'. Get it with: gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix"
  type        = string

  validation {
    condition     = startswith(var.github_oidc_sub_prefix, "repo:")
    error_message = "github_oidc_sub_prefix must start with 'repo:'."
  }
}

variable "force_destroy_state_bucket" {
  description = "Let `terraform destroy` delete the state bucket even if it still holds objects/versions. It is read from state, so it must be applied before destroy takes effect (see README)."
  type        = bool
}
