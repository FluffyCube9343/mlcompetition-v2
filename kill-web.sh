#!/usr/bin/env bash
#
# kill-web.sh - tear down ONLY the web tier (everything deploy-web.sh made).
#
# Deletes: the ECS service + cluster, task definition revisions, the web
# ECR repo, the security group, the log group, and the execution role.
# It does NOT touch anything deploy.sh created: the Lambdas, the scores
# table, and the submission role all survive, so redeploying the web tier
# later is just ./deploy-web.sh again.
#
# Destroys no data - the leaderboard lives in DynamoDB, not here - so no
# typed confirmation.
#
# Usage:
#   ./kill-web.sh                 # tear down in us-east-1
#   REGION=us-west-2 ./kill-web.sh

set -euo pipefail
cd "$(dirname "$0")"

REGION="${REGION:-us-east-1}"

# same constants as deploy-web.sh - keep the two files in sync
WEB_REPO="competition-web"
CLUSTER="competition-cluster"
SERVICE="competition-web"
TASK_FAMILY="competition-web"
SG_NAME="competition-web-sg"
LOG_GROUP="/ecs/competition-web"
EXEC_ROLE="competition-web-exec-role"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "==> Tearing down the web tier in ${REGION} (account ${ACCOUNT_ID})"

cluster_active() {
  aws ecs describe-clusters --clusters "$CLUSTER" --region "$REGION" \
    --query "clusters[?status=='ACTIVE']" --output text | grep -q .
}
service_active() {
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
    --query "services[?status=='ACTIVE']" --output text 2>/dev/null | grep -q .
}

# ---------------------------------------------------------------------------
echo "==> Deleting the service"
# scale to 0 first: delete-service refuses a service that still wants tasks
if cluster_active && service_active; then
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
    --desired-count 0 --region "$REGION" >/dev/null
  aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION"
  aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --region "$REGION" >/dev/null
  echo "    deleted ${SERVICE}"
else
  echo "    service not found - skipping"
fi

# ---------------------------------------------------------------------------
echo "==> Deleting task definition revisions"
# task defs only deregister (never truly delete); deregister every revision of the family
REV_ARN="$(aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" --region "$REGION" \
  --query 'taskDefinitionArns[]' --output text 2>/dev/null || true)"
if [ -n "$REV_ARN" ]; then
  for arn in $REV_ARN; do
    aws ecs deregister-task-definition --task-definition "$arn" --region "$REGION" >/dev/null
    echo "    deregistered ${arn##*/}"
  done
else
  echo "    no revisions found - skipping"
fi

# ---------------------------------------------------------------------------
echo "==> Deleting the cluster"
if cluster_active; then
  aws ecs delete-cluster --cluster "$CLUSTER" --region "$REGION" >/dev/null
  echo "    deleted ${CLUSTER}"
else
  echo "    cluster not found - skipping"
fi

# ---------------------------------------------------------------------------
echo "==> Deleting the security group"
# task ENIs linger a minute after the tasks stop; retry until AWS lets go
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || true)"
SG_ID=""
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  SG_ID="$(aws ec2 describe-security-groups --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || true)"
fi
if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  for attempt in 1 2 3 4 5 6; do
    if aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null; then
      echo "    deleted ${SG_NAME}"
      break
    fi
    echo "    ENI still detaching - retrying in 10s (attempt ${attempt}/6)"
    sleep 10
    if [ "$attempt" = "6" ]; then
      echo "    WARNING: could not delete ${SG_NAME} (${SG_ID}) - delete it in the VPC console" >&2
    fi
  done
else
  echo "    security group not found - skipping"
fi

# ---------------------------------------------------------------------------
echo "==> Deleting ECR repository"
# --force: ECR refuses to delete a repo that still holds images
if aws ecr describe-repositories --repository-names "$WEB_REPO" --region "$REGION" >/dev/null 2>&1; then
  aws ecr delete-repository --repository-name "$WEB_REPO" --force --region "$REGION" >/dev/null
  echo "    deleted ${WEB_REPO}"
else
  echo "    ${WEB_REPO} not found - skipping"
fi

# ---------------------------------------------------------------------------
echo "==> Deleting log group"
if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$REGION" \
    --query "logGroups[?logGroupName=='${LOG_GROUP}']" --output text | grep -q .; then
  aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$REGION"
  echo "    deleted ${LOG_GROUP}"
else
  echo "    log group not found - skipping"
fi

# ---------------------------------------------------------------------------
echo "==> Deleting the execution role"
if aws iam get-role --role-name "$EXEC_ROLE" >/dev/null 2>&1; then
  for arn in $(aws iam list-attached-role-policies --role-name "$EXEC_ROLE" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$EXEC_ROLE" --policy-arn "$arn"
  done
  aws iam delete-role --role-name "$EXEC_ROLE"
  echo "    deleted ${EXEC_ROLE}"
else
  echo "    ${EXEC_ROLE} not found - skipping"
fi

echo "==> Web tier down. Lambdas, scores table, and submission role untouched."
