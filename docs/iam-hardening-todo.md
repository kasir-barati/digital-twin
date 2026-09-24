## Known Gaps

The scoping above stops accidents and most misuse, but three paths remain. They're tracked here

1. **CI role takeover.** `BootstrapGithubActionsRole` allows `iam:UpdateAssumeRolePolicy` and an unconditioned `iam:AttachRolePolicy` on `github-actions-twin-deploy`. `aiengineer` could attach `AdministratorAccess` to that role, make the role trust itself, and assume it.
2. **Boundary rewrite.** `BootstrapBoundaryPolicy` allows `iam:CreatePolicyVersion` on `ci-managed-role-boundary`. `aiengineer` could loosen the boundary, and every `*-lambda-role` would then be capped by the weaker version.
3. **`PassRole` through `AWSLambda_FullAccess`.** That AWS managed policy grants `iam:PassRole` on `*` whenever the role is passed to Lambda. IAM allows are additive, so this bypasses `LambdaRolePassToLambdaOnly`: `aiengineer` can run a Lambda under **any** role in the account that trusts `lambda.amazonaws.com`.

Until those are closed, guard `aiengineer`'s access key as you would an admin credential.

## Close the remaining `aiengineer` escalation paths

Status: **not implemented**. The README's [Known gaps](../README.md#known-gaps) section describes the current state. This file proposes fixes and explains how to test them before changing anything in AWS.

Account ID used below: `637423441352`. Replace it if yours is different.

## The three gaps

| #   | Path                                                                                                                                                                       | Comes from                                                       | Proposed fix                                                    |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------------------------------- |
| 1   | `UpdateAssumeRolePolicy` + `AttachRolePolicy`/`PutRolePolicy` on `github-actions-twin-deploy`, so `aiengineer` can make the CI role trust itself, add admin, and assume it | `BootstrapGithubActionsRole` in `TwinTerraformOperator`          | [Fix A](#fix-a-time-box-the-bootstrap-permissions-gaps-1-and-2) |
| 2   | `CreatePolicyVersion` on `ci-managed-role-boundary`, so `aiengineer` can loosen the boundary that caps every `*-lambda-role`                                               | `BootstrapBoundaryPolicy` in `TwinTerraformOperator`             | [Fix A](#fix-a-time-box-the-bootstrap-permissions-gaps-1-and-2) |
| 3   | `iam:PassRole` on `*` (to Lambda), so `aiengineer` can run a Lambda under any role that trusts `lambda.amazonaws.com`                                                      | AWS managed `AWSLambda_FullAccess` (possibly others, see step 0) | [Fix B](#fix-b-explicit-deny-on-passrole-gap-3)                 |

## Step 0: audit which attached managed policies grant IAM actions

Don't rely on memory for what AWS managed policies contain. They change over time. Run this as `aiengineer` or as an admin:

```bash
for arn in \
  arn:aws:iam::aws:policy/AmazonS3FullAccess \
  arn:aws:iam::aws:policy/AWSLambda_FullAccess \
  arn:aws:iam::aws:policy/AmazonAPIGatewayAdministrator \
  arn:aws:iam::aws:policy/CloudFrontFullAccess \
  arn:aws:iam::aws:policy/CloudWatchFullAccessV2 \
  arn:aws:iam::aws:policy/AmazonBedrockFullAccess \
  arn:aws:iam::aws:policy/IAMUserChangePassword; do
  v=$(aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)
  echo "== $arn ($v)"
  aws iam get-policy-version --policy-arn "$arn" --version-id "$v" \
    --query PolicyVersion.Document --output json |
    jq '[.Statement[] | select((.Action | if type=="array" then . else [.] end) | any(startswith("iam:") or . == "*"))]'
done
```

Any statement listed there that allows `iam:PassRole`, `iam:Create*`, `iam:Put*`, `iam:Attach*` or `iam:Update*` needs to be covered by Fix B or an equivalent deny.

## Fix A: time-box the bootstrap permissions (gaps 1 and 2)

Neither gap can be closed with a condition key. IAM can't inspect the _content_ of a trust policy, an inline policy or a policy version. The bootstrap stack does need those permissions, but only while you run `terraform apply` or `terraform destroy` in `terraform-bootstrap/`, which happens rarely. So `aiengineer` should hold them only during that window.

1. Split `TwinTerraformOperator` into two customer-managed policies:
   - `TwinTerraformOperator` (always attached): everything **except** `BootstrapListOidcProviders`, `BootstrapGithubOidcProvider`, `BootstrapGithubActionsRole` and `BootstrapBoundaryPolicy`.
   - `TwinBootstrapOperator` (attached only during bootstrap): those four statements plus `CallerIdentity`.
2. Only root or a separate admin identity attaches and detaches `TwinBootstrapOperator`. `aiengineer` must not have `iam:AttachUserPolicy` on itself. It doesn't today; keep it that way.
3. Bootstrap workflow:
   ```bash
   # as admin
   aws iam attach-user-policy --user-name aiengineer \
     --policy-arn arn:aws:iam::637423441352:policy/TwinBootstrapOperator
   # as aiengineer
   cd terraform-bootstrap && terraform apply    # or destroy
   # as admin, right after
   aws iam detach-user-policy --user-name aiengineer \
     --policy-arn arn:aws:iam::637423441352:policy/TwinBootstrapOperator
   ```
4. The policy count stays at 8 day-to-day (9 during bootstrap), under the quota of 10.

Things to double-check:

- Does `terraform plan` in `terraform-bootstrap/` still need to **read** the OIDC provider, the CI role and the boundary policy without the bootstrap policy attached? If you want to run `plan` without the bootstrap policy, keep a read-only subset (`iam:Get*`, `iam:List*` on those three ARNs) in `TwinTerraformOperator`. Read access doesn't reopen either gap.
- The app stack (`terraform/`) only _references_ the boundary by ARN. It doesn't read the policy, so it shouldn't need anything from `TwinBootstrapOperator`. Confirm with a `./scripts/deploy.sh dev` while the bootstrap policy is detached.

**Alternative (not recommended):** keep the permissions attached, but give `github-actions-twin-deploy` its own permissions boundary created by an admin, which `aiengineer` can't edit. Then require `iam:PermissionsBoundary` on `CreateRole`/`PutRolePolicy`/`AttachRolePolicy` for that ARN. This caps what a takeover could reach, but `aiengineer` could still assume the CI role through a rewritten trust policy. It's also more moving parts than the time-box.

## Fix B: explicit deny on `PassRole` (gap 3)

IAM allows can't narrow each other, but an explicit `Deny` overrides every `Allow`, including the one inside `AWSLambda_FullAccess`. Add this statement to `TwinTerraformOperator`:

```json
{
  "Sid": "DenyPassRoleExceptLambdaRole",
  "Effect": "Deny",
  "Action": "iam:PassRole",
  "NotResource": "arn:aws:iam::637423441352:role/*-lambda-role"
}
```

`aiengineer` never needs to pass any other role. `github-actions-twin-deploy` is assumed through OIDC, not passed.

A deny is simpler than replacing `AWSLambda_FullAccess` with a hand-written Lambda policy. You can still do that replacement later if you also want to scope the Lambda actions themselves.

## Testing

### 1. Simulator first (nothing changes in AWS)

`aws iam simulate-principal-policy` evaluates everything attached to `aiengineer` (user policies and group policies). Run it as an admin, because `aiengineer` doesn't have `iam:SimulatePrincipalPolicy`.

```bash
USER_ARN=arn:aws:iam::637423441352:user/aiengineer
CI_ROLE=arn:aws:iam::637423441352:role/github-actions-twin-deploy
BOUNDARY=arn:aws:iam::637423441352:policy/ci-managed-role-boundary

# Gap 1: expect implicitDeny/explicitDeny after Fix A (while TwinBootstrapOperator is detached)
aws iam simulate-principal-policy --policy-source-arn "$USER_ARN" \
  --action-names iam:UpdateAssumeRolePolicy iam:PutRolePolicy iam:AttachRolePolicy \
  --resource-arns "$CI_ROLE" \
  --context-entries ContextKeyName=iam:PolicyARN,ContextKeyValues=arn:aws:iam::aws:policy/AdministratorAccess,ContextKeyType=string \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table

# Gap 2: expect implicitDeny after Fix A
aws iam simulate-principal-policy --policy-source-arn "$USER_ARN" \
  --action-names iam:CreatePolicyVersion \
  --resource-arns "$BOUNDARY" \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table

# Gap 3: pick any role that is NOT *-lambda-role but trusts Lambda. Expect explicitDeny after Fix B
aws iam simulate-principal-policy --policy-source-arn "$USER_ARN" \
  --action-names iam:PassRole \
  --resource-arns arn:aws:iam::637423441352:role/SOME-OTHER-ROLE \
  --context-entries ContextKeyName=iam:PassedToService,ContextKeyValues=lambda.amazonaws.com,ContextKeyType=string \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table

# Regression: this must still be "allowed"
aws iam simulate-principal-policy --policy-source-arn "$USER_ARN" \
  --action-names iam:PassRole \
  --resource-arns arn:aws:iam::637423441352:role/twin-dev-lambda-role \
  --context-entries ContextKeyName=iam:PassedToService,ContextKeyValues=lambda.amazonaws.com,ContextKeyType=string \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table
```

Run the same commands **before** the change too. The gap tests should report `allowed`, which confirms that the tests actually detect the gaps.

To try a policy draft before creating it in AWS, use `simulate-custom-policy --policy-input-list file://draft.json` with the same actions and context entries. Note that it only evaluates the policies you pass it, not the ones already attached to the user.

### 2. Don't prove the gaps live

Don't "prove" a gap by actually running `attach-role-policy ... AdministratorAccess` or `create-policy-version` against the real resources. If the fix isn't in place, that call **succeeds** and you have created the escalation yourself. The simulator is enough for the negative cases.

### 3. End-to-end regression (positive cases)

After applying the fixes, make sure the normal workflows still work as `aiengineer`:

1. `terraform plan` in `terraform-bootstrap/` with `TwinBootstrapOperator` **attached**. It should show no changes. Then detach the policy.
2. `./scripts/deploy.sh dev` with `TwinBootstrapOperator` **detached**. The apply should succeed, including the Lambda role (CreateRole with boundary, PassRole to Lambda).
3. `./scripts/destroy.sh dev`, then deploy again. This covers `DeleteRole`, `DetachRolePolicy` and `DeleteRolePolicy`.
4. Locally: `make start_dev` in `backend/` and send one chat message (Bedrock + S3).
5. If you use a custom domain, run a `prod` plan (ACM/Route 53).

If any step fails with `AccessDenied`, the error names the action and resource. Add the narrowest statement that allows it, and re-run the simulator tests to check that it didn't reopen a gap.

## When done

- Update the table and JSON in [README step 1](../README.md#1-one-time-iam-setup-for-aiengineer) and the `for arn in ...` attach loop.
- Replace the README's "Known gaps" section with a short note about the bootstrap time-box.
- Delete this file.
