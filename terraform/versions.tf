terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "twin-terraform-state-637423441352"
    key          = "twin/terraform.tfstate"
    region       = "eu-central-1" # We cannot use variables/locals/data here: https://developer.hashicorp.com/terraform/language/backend#define-a-backend-block
    use_lockfile = true
    encrypt      = true
  }
}

# We're not declaring the AWS provider "twice". We're declaring two different provider configurations of the same AWS provider.
# Distinguished by the alias; one has no alias (default), the other has an alias of "us_east_1".
#
# default_tags is set on BOTH provider configurations so every resource gets these tags
# automatically, regardless of which provider (default or aliased) it's created with.
# Terraform merges default_tags with any resource-level `tags`, so this replaces the need
# for a shared common_tags local passed into every resource.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

# ACM certificates used by CloudFront must be requested in us-east-1, regardless of
# where the rest of the stack lives.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
