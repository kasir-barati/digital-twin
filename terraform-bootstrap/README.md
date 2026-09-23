# terraform-bootstrap

This stack provisions the resources that must exist **before** GitHub Actions can run any Terraform in `../terraform`:

- The S3 bucket used as the remote state backend for `../terraform`.
- The GitHub OIDC provider (`token.actions.githubusercontent.com`).
- The IAM role (`github-actions-twin-deploy`) that GitHub Actions assumes via `AssumeRoleWithWebIdentity`. No long-lived AWS access keys in CI.

## Why this is Separate from `../terraform`

GitHub Actions can't create its own IAM role or the state bucket it needs to run. It would need credentials that don't exist yet. This is the classic bootstrap chicken-and-egg problem, and the standard fix is to split off a minimal "bootstrap" layer that a human applies once, out-of-band, with their
own local AWS credentials.

## Rules

- **Only a human runs `terraform apply` here, from their own machine.** This directory is never wired into a CI workflow.
- This stack's own Terraform state stays **local** (not in the S3 backend it creates for the other stack), it changes rarely and doesn't need remote locking/collaboration. But of course you can later move the state files to an AWS S3 bucket if you want to.
- After applying, copy the `github_actions_role_arn` output into the GitHub repo's Actions secrets/variables so the CI workflow can assume it.

## `TerraformGitHubActionsBootstrapPolicy` Custom Policy

This stack is applied by a non-admin IAM user, not the account root or an admin role. That user isn't managed by this Terraform (or any Terraform in this repo). It was created directly in AWS Console so its permissions have to be attached out-of-band, once.

Attach the policy below to that user (console: IAM → Users → `aiengineer` → Add permissions → Create inline policy → JSON tab; or `aws iam put-user-policy --user-name aiengineer --policy-name terraform-bootstrap --policy-document file://policy.json`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StateBucket",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:DeleteBucket",
        "s3:GetBucketVersioning",
        "s3:PutBucketVersioning",
        "s3:GetEncryptionConfiguration",
        "s3:PutEncryptionConfiguration",
        "s3:GetBucketPublicAccessBlock",
        "s3:PutBucketPublicAccessBlock",
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketVersions"
      ],
      "Resource": "arn:aws:s3:::twin-terraform-state-637423441352"
    },
    {
      "Sid": "StateBucketObjects",
      "Effect": "Allow",
      "Action": ["s3:DeleteObject", "s3:DeleteObjectVersion"],
      "Resource": "arn:aws:s3:::twin-terraform-state-637423441352/*"
    },
    {
      "Sid": "ListOidcProviders",
      "Effect": "Allow",
      "Action": "iam:ListOpenIDConnectProviders",
      "Resource": "*"
    },
    {
      "Sid": "GithubOidcProvider",
      "Effect": "Allow",
      "Action": [
        "iam:CreateOpenIDConnectProvider",
        "iam:DeleteOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider",
        "iam:TagOpenIDConnectProvider",
        "iam:UntagOpenIDConnectProvider",
        "iam:UpdateOpenIDConnectProviderThumbprint"
      ],
      "Resource": "arn:aws:iam::637423441352:oidc-provider/token.actions.githubusercontent.com"
    },
    {
      "Sid": "GithubActionsDeployRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:UpdateAssumeRolePolicy",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:ListRolePolicies",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole"
      ],
      "Resource": "arn:aws:iam::637423441352:role/github-actions-twin-deploy"
    },
    {
      "Sid": "CiManagedRoleBoundaryPolicy",
      "Effect": "Allow",
      "Action": [
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListPolicyVersions",
        "iam:CreatePolicyVersion",
        "iam:DeletePolicyVersion",
        "iam:TagPolicy",
        "iam:UntagPolicy"
      ],
      "Resource": "arn:aws:iam::637423441352:policy/ci-managed-role-boundary"
    },
    {
      "Sid": "CallerIdentity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
```

Why this is safe to grant — it does **not** reopen the `CreateRole` + `AttachRolePolicy` + `PassRole` privilege-escalation path (see [this flashcard](https://kasir-barati.github.io/aws-flashcards/iam-createrole-passrole-privesc.html) for the general pattern):

- `iam:CreateRole` and `iam:AttachRolePolicy`/`iam:PutRolePolicy` are pinned to the exact ARN `role/github-actions-twin-deploy` — `aiengineer` cannot create or modify any _other_ role in the account, so it can't mint a fresh admin-trusted role.
- `iam:CreatePolicy`/`iam:CreatePolicyVersion` are pinned to the exact ARN `policy/ci-managed-role-boundary` — it can't create or rewrite arbitrary managed policies either.
- `aiengineer` is **not** granted `iam:PassRole` at all. It never needs to pass this role to a service (unlike the GitHub Actions role it creates, which does need `PassRole` — scoped separately in `main.tf`), so that leg of the escalation chain is simply absent.
- None of the actions above accept `Resource: "*"` except `sts:GetCallerIdentity` (read-only, required by AWS to support resource-level permissions) and `iam:ListOpenIDConnectProviders` (a list action AWS does not support scoping — see the [AWS IAM action reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_awsidentityandaccessmanagement.html) for which actions support resource-level permissions).

## Usage

```bash
aws configure --profile twin-dev
cd terraform-bootstrap
terraform init
terraform apply
```

## Thumbprint

This is a SHA-1 fingerprint of a cert in GitHub's OIDC TLS chain, originally used by AWS to pin trust when fetching GitHub's signing keys. The IAM API still requires a value here, but since mid-2023 AWS validates GitHub (and other well-known providers) against its own managed CA trust store instead of this thumbprint, so it's effectively a required formality rather than an active security control.

You can see the latest thumbprint fingerprint here: https://github.blog/changelog/2023-06-27-github-actions-update-on-oidc-integration-with-aws/
