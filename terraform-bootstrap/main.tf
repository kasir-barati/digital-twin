resource "aws_s3_bucket" "terraform_state" {
  bucket        = "twin-terraform-state-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.force_destroy_state_bucket
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# GitHub OIDC Provider: this creates an IAM role that GitHub Actions can assume
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # Learn more: ../README.md#the-oidc-thumbprint
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions" {
  name = "github-actions-twin-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = [
              for env in ["dev", "test", "prod"] : "${var.github_oidc_sub_prefix}:environment:${env}"
            ]
          }
        }
      }
    ]
  })

  tags = {
    Name       = "GitHub Actions Deploy Role"
    Repository = var.github_repository
    ManagedBy  = "terraform"
  }
}

# Attach necessary policies
resource "aws_iam_role_policy_attachment" "github_lambda" {
  policy_arn = "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
  role       = aws_iam_role.github_actions.name
}

resource "aws_iam_role_policy_attachment" "github_s3" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  role       = aws_iam_role.github_actions.name
}

resource "aws_iam_role_policy_attachment" "github_apigateway" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonAPIGatewayAdministrator"
  role       = aws_iam_role.github_actions.name
}

resource "aws_iam_role_policy_attachment" "github_cloudfront" {
  policy_arn = "arn:aws:iam::aws:policy/CloudFrontFullAccess"
  role       = aws_iam_role.github_actions.name
}

resource "aws_iam_role_policy_attachment" "github_iam_read" {
  policy_arn = "arn:aws:iam::aws:policy/IAMReadOnlyAccess"
  role       = aws_iam_role.github_actions.name
}

resource "aws_iam_role_policy_attachment" "github_bedrock" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
  role       = aws_iam_role.github_actions.name
}

resource "aws_iam_role_policy_attachment" "github_dynamodb" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
  role       = aws_iam_role.github_actions.name
}

resource "aws_iam_role_policy_attachment" "github_acm" {
  policy_arn = "arn:aws:iam::aws:policy/AWSCertificateManagerFullAccess"
  role       = aws_iam_role.github_actions.name
}

resource "aws_iam_role_policy_attachment" "github_route53" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
  role       = aws_iam_role.github_actions.name
}

# Tag key deliberately named for what it authorizes, not a generic label like "ManagedBy" (which
# already means "provisioned by terraform" everywhere else in this codebase and would be
# ambiguous reused here). IamManagedByRole = "<role name>" means exactly one thing: the IAM role
# with that name is allowed to create/update/pass this specific resource. Nothing else reads it.
#
# The value is deliberately NOT based on var.project_name: that variable is set independently in
# this stack's tfvars and in ../terraform's tfvars, so a rename in only one place would silently
# desync a name-prefix-based scope. The CI role's own name is a stable literal (hardcoded above,
# unaffected by project renames), so tagging against it can't drift the same way. Any role
# ../terraform creates for this app (e.g. the Lambda execution role) must carry
# tags = { IamManagedByRole = <this same value> } for this CI role to be able to touch it.
locals {
  ci_managed_tag_key   = "IamManagedByRole"
  ci_managed_tag_value = aws_iam_role.github_actions.name
}

# Ceiling on what any role the GitHub Actions deploy role creates can ever do, regardless of
# what policy later gets attached or inlined onto it. A permissions boundary intersects with
# the role's own permissions, so even a mistaken "AdministratorAccess"-equivalent inline policy
# on a bounded role grants nothing beyond what's allowed here.
resource "aws_iam_policy" "ci_managed_role_boundary" {
  name        = "ci-managed-role-boundary"
  description = "Permissions boundary required on every IAM role the GitHub Actions deploy role creates."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAppServices"
        Effect = "Allow"
        Action = [
          "lambda:*",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "s3:*",
          "dynamodb:*",
          "bedrock:*",
          "apigateway:*",
          "cloudfront:*",
          "acm:*",
          "route53:*",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyIamAndAccountControl"
        Effect = "Deny"
        Action = [
          "iam:*",
          "sts:*",
          "organizations:*",
          "account:*",
        ]
        Resource = "*"
      }
    ]
  })
}

# Custom policy for additional permissions
resource "aws_iam_role_policy" "github_additional" {
  name = "github-actions-additional"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadAndManageAppRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:DeleteRole",
          "iam:DetachRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:UpdateAssumeRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/${local.ci_managed_tag_key}" = local.ci_managed_tag_value
          }
        }
      },
      {
        # Only lets this role bring NEW roles into scope by tagging them at creation time —
        # it can't retag an existing, unmanaged role to pull it into scope later (TagRole/
        # UntagRole above already require the role to carry the tag before they apply).
        Sid      = "CreateAppRolesWithBoundary"
        Effect   = "Allow"
        Action   = "iam:CreateRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/${local.ci_managed_tag_key}" = local.ci_managed_tag_value
            "iam:PermissionsBoundary"                    = aws_iam_policy.ci_managed_role_boundary.arn
          }
        }
      },
      {
        Sid      = "AttachManagedPoliciesExceptAdmin"
        Effect   = "Allow"
        Action   = "iam:AttachRolePolicy"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/${local.ci_managed_tag_key}" = local.ci_managed_tag_value
          }
          ArnNotEquals = {
            "iam:PolicyARN" = [
              "arn:aws:iam::aws:policy/AdministratorAccess",
              aws_iam_policy.ci_managed_role_boundary.arn,
            ]
          }
        }
      },
      {
        Sid      = "InlinePoliciesOnAppRoles"
        Effect   = "Allow"
        Action   = "iam:PutRolePolicy"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/${local.ci_managed_tag_key}" = local.ci_managed_tag_value
          }
        }
      },
      {
        Sid      = "PassAppRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/${local.ci_managed_tag_key}" = local.ci_managed_tag_value
          }
        }
      },
      {
        # For ../terraform's aws_cloudwatch_log_group.lambda none of the managed policies above grant log group management.
        Sid    = "ManageLambdaLogGroups"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy",
          "logs:DeleteRetentionPolicy",
          "logs:TagResource",
          "logs:UntagResource",
          "logs:TagLogGroup",
          "logs:UntagLogGroup",
          "logs:ListTagsForResource",
          "logs:ListTagsLogGroup",
        ]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*"
      },
      {
        Sid      = "DescribeLogGroups"
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      },
      {
        Sid      = "CallerIdentity"
        Effect   = "Allow"
        Action   = "sts:GetCallerIdentity"
        Resource = "*"
      }
    ]
  })
}
