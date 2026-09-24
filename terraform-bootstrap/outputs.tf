output "state_bucket_name" {
  description = "Dumps the ID of the twin-terraform-state-<AWS_ACCOUNT_ID> bucket"
  value       = aws_s3_bucket.terraform_state.id
}

# The GH Actions role trusts only tokens whose `sub` is `<github_oidc_sub_prefix>:environment:{dev,test,prod}`.
# No long-lived keys.
output "github_actions_role_arn" {
  description = "The ARN used by the IAM role used in the GitHub Actions"
  value       = aws_iam_role.github_actions.arn
}
