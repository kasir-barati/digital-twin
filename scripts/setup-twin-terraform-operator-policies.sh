#!/usr/bin/env bash
# setup-twin-terraform-operator-policies.sh
#
# Creates the TwinTerraformOperator IAM policy and attaches it plus a set of AWS managed policies to the `aiengineer` IAM user.
#
# Usage:
#   ./setup-twin-terraform-operator-policies.sh <AWS_ACCOUNT_ID>
#
# Example:
#   ./setup-twin-terraform-operator-policies.sh 123456789123

set -euo pipefail

# ---- Args ---------------------------------------------------------------
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <AWS_ACCOUNT_ID>" >&2
  exit 1
fi

ACCOUNT_ID="$1"

if ! [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "Error: AWS account ID must be a 12-digit number (got '$ACCOUNT_ID')." >&2
  exit 1
fi

# ---- Config -------------------------------------------------------------
USER_NAME="aiengineer"
POLICY_NAME="TwinTerraformOperator"
POLICY_FILE="twin-terraform-operator.json"
CUSTOM_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

MANAGED_POLICY_ARNS=(
  "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
  "arn:aws:iam::aws:policy/AmazonAPIGatewayAdministrator"
  "arn:aws:iam::aws:policy/CloudFrontFullAccess"
  "arn:aws:iam::aws:policy/CloudWatchFullAccessV2"
  "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
  "arn:aws:iam::aws:policy/IAMUserChangePassword"
)

# ---- Preflight ----------------------------------------------------------
if [[ ! -f "$POLICY_FILE" ]]; then
  echo "Error: policy document '$POLICY_FILE' not found in $(pwd)." >&2
  exit 1
fi

command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI not installed." >&2; exit 1; }

# ---- Create custom policy ----------------------------------------------
echo "==> Creating IAM policy: ${POLICY_NAME}"
if aws iam get-policy --policy-arn "$CUSTOM_POLICY_ARN" >/dev/null 2>&1; then
  echo "    Policy already exists, skipping create."
else
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://${POLICY_FILE}"
fi

# ---- Attach policies ----------------------------------------------------
for arn in "${MANAGED_POLICY_ARNS[@]}" "$CUSTOM_POLICY_ARN"; do
  echo "==> Attaching ${arn} to user ${USER_NAME}"
  aws iam attach-user-policy \
    --user-name "$USER_NAME" \
    --policy-arn "$arn"
done

echo "==> Done."
