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
