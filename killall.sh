#!/usr/bin/env bash
#
# killall.sh - tear down everything deploy.sh created.
#
# Deletes: both Lambda functions, all three IAM roles, the ECR repo
# (with all pushed images), and the competition-scores DynamoDB table
# (THIS DESTROYS ALL SAVED SCORES).
#
# Idempotent: each delete is guarded by an existence check, so a partial
# deploy or a second run won't error out.
#
# Usage:
#   ./killall.sh                 # tear down in us-east-1
#   REGION=us-west-2 ./killall.sh

set -euo pipefail
cd "$(dirname "$0")"

REGION="${REGION:-us-east-1}"

# same constants as deploy.sh - keep the two files in sync
TABLE_NAME="competition-scores"
ECR_REPO="competition-runner"
RUNNER_FN="competition-runner"
GRADER_FN="competition-grader"
RUNNER_ROLE="competition-runner-role"
GRADER_ROLE="competition-grader-role"
SUBMISSION_ROLE="competition-submission-role"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

cat <<EOF
This will permanently delete, in ${REGION} (account ${ACCOUNT_ID}):

  - Lambda functions:  ${RUNNER_FN}, ${GRADER_FN}
  - IAM roles:         ${RUNNER_ROLE}, ${GRADER_ROLE}, ${SUBMISSION_ROLE}
  - ECR repository:    ${ECR_REPO} (all images)
  - DynamoDB table:    ${TABLE_NAME} (ALL SAVED TEAM SCORES)

It does NOT touch the submission service if you already deployed it to
ECS/EC2, or the runner's VPC attachment (detached automatically when the
function is deleted, but the ENIs can linger a few minutes).
EOF

# typed confirmation: this destroys score data
read -r -p "Type 'delete' to confirm: " confirm
if [ "$confirm" != "delete" ]; then
  echo "Aborted."
  exit 1
fi

# ---------------------------------------------------------------------------
echo "==> Deleting Lambda functions"
# functions first, so the role/ECR deletes have no dangling consumers
for fn in "$RUNNER_FN" "$GRADER_FN"; do
  if aws lambda get-function --function-name "$fn" --region "$REGION" >/dev/null 2>&1; then
    aws lambda delete-function --function-name "$fn" --region "$REGION"
    echo "    deleted ${fn}"
  else
    echo "    ${fn} not found - skipping"
  fi
done

# ---------------------------------------------------------------------------
echo "==> Deleting IAM roles"
# a role deletes only after its managed and inline policies are removed;
# enumerate both so hand-edited policies don't block the delete
delete_role() {
  local role="$1"
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    echo "    ${role} not found - skipping"
    return
  fi
  local arn name
  for arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$arn"
  done
  for name in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$name"
  done
  aws iam delete-role --role-name "$role"
  echo "    deleted ${role}"
}
delete_role "$RUNNER_ROLE"
delete_role "$GRADER_ROLE"
delete_role "$SUBMISSION_ROLE"

# ---------------------------------------------------------------------------
echo "==> Deleting ECR repository"
# --force: ECR refuses to delete a repo that still holds images
if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" >/dev/null 2>&1; then
  aws ecr delete-repository --repository-name "$ECR_REPO" --force --region "$REGION" >/dev/null
  echo "    deleted ${ECR_REPO}"
else
  echo "    ${ECR_REPO} not found - skipping"
fi

# ---------------------------------------------------------------------------
echo "==> Deleting DynamoDB table"
# last, because it is the irreversible one
if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null
  aws dynamodb wait table-not-exists --table-name "$TABLE_NAME" --region "$REGION"
  echo "    deleted ${TABLE_NAME}"
else
  echo "    ${TABLE_NAME} not found - skipping"
fi

echo "==> Teardown complete."
