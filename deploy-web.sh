#!/usr/bin/env bash
#
# deploy-web.sh - put the submission service on ECS Fargate with a public IP.
# Idempotent: every step is create-or-update, safe to re-run.
#
# Run AFTER deploy.sh - this reuses the competition-submission-role it makes.
#
# Usage:
#   ./deploy-web.sh                 # deploy to us-east-1
#   REGION=us-west-2 ./deploy-web.sh
#
# Cost note: a Fargate task bills per second while it runs. Spin this up on
# competition day, then ./kill-web.sh after - idle time is real money.

set -euo pipefail

cd "$(dirname "$0")"  # behave the same no matter where it is invoked from

REGION="${REGION:-us-east-1}"

# fixed names: kill-web.sh and the task env reference these exact strings
WEB_REPO="competition-web"
CLUSTER="competition-cluster"
SERVICE="competition-web"
TASK_FAMILY="competition-web"
SG_NAME="competition-web-sg"
LOG_GROUP="/ecs/competition-web"
EXEC_ROLE="competition-web-exec-role"
SUBMISSION_ROLE="competition-submission-role"
GRADER_FN="competition-grader"
PORT=80

echo "==> Resolving AWS account"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${WEB_REPO}:latest"
echo "    account: ${ACCOUNT_ID}  region: ${REGION}"

# deploy.sh must have run first - it owns the submission role and the grader
if ! aws iam get-role --role-name "$SUBMISSION_ROLE" >/dev/null 2>&1; then
  echo "    ERROR: ${SUBMISSION_ROLE} not found. Run ./deploy.sh first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
echo "==> [1/6] ECR repo + web image"
if ! aws ecr describe-repositories --repository-names "$WEB_REPO" --region "$REGION" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "$WEB_REPO" --region "$REGION" >/dev/null
  echo "    repo created"
else
  echo "    repo already exists"
fi

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# force x86_64: Fargate defaults to amd64 and a plain build on Apple Silicon produces arm64
docker build --platform linux/amd64 -t "${WEB_REPO}:latest" submission-service/
docker tag "${WEB_REPO}:latest" "$IMAGE_URI"
docker push "$IMAGE_URI"
echo "    pushed ${IMAGE_URI}"

# ---------------------------------------------------------------------------
echo "==> [2/6] Task execution role + log group"
# two different roles: the task role (submission-role) is what the APP can do;
# the execution role is what FARGATE can do (pull from ECR, write logs)
EXEC_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if aws iam get-role --role-name "$EXEC_ROLE" >/dev/null 2>&1; then
  echo "    role ${EXEC_ROLE} already exists"
else
  aws iam create-role --role-name "$EXEC_ROLE" --assume-role-policy-document "$EXEC_TRUST" >/dev/null
  echo "    role ${EXEC_ROLE} created"
fi
aws iam attach-role-policy \
  --role-name "$EXEC_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$REGION" \
    --query "logGroups[?logGroupName=='${LOG_GROUP}']" --output text | grep -q .; then
  echo "    log group already exists"
else
  aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$REGION"
  echo "    log group created"
fi

# ---------------------------------------------------------------------------
echo "==> [3/6] Network: default VPC + security group"
# Fargate needs subnets; the default VPC's subnets auto-assign public IPs and
# route to the internet - correct for a public web tier
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$REGION")"
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "    ERROR: no default VPC in ${REGION}. Create one (VPC console -> Actions -> Create default VPC) and re-run." >&2
  exit 1
fi
SUBNETS="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[].SubnetId' --output text --region "$REGION")"
SUBNET_CSV="$(echo "$SUBNETS" | tr '\t' ',')"
echo "    vpc: ${VPC_ID}  subnets: ${SUBNET_CSV}"

if ! SG_ID="$(aws ec2 describe-security-groups --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null)" \
    || [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID="$(aws ec2 create-security-group --group-name "$SG_NAME" \
    --description "competition-web: public http on ${PORT}" --vpc-id "$VPC_ID" --region "$REGION" \
    --query GroupId --output text)"
  echo "    security group created: ${SG_ID}"
else
  echo "    security group already exists: ${SG_ID}"
fi

# open inbound http to the world: in-person event, open submission mode (see README)
if ! aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`${PORT}\` && ToPort==\`${PORT}\` && IpProtocol=='tcp']" \
    --output text | grep -q .; then
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
    --protocol tcp --port "$PORT" --cidr 0.0.0.0/0 >/dev/null
  echo "    opened tcp/${PORT} to 0.0.0.0/0"
fi

# ---------------------------------------------------------------------------
echo "==> [4/6] Cluster + task definition"
if aws ecs describe-clusters --clusters "$CLUSTER" --region "$REGION" \
    --query "clusters[?status=='ACTIVE']" --output text | grep -q .; then
  echo "    cluster already exists"
else
  aws ecs create-cluster --cluster-name "$CLUSTER" --region "$REGION" >/dev/null
  echo "    cluster created"
fi

# smallest Fargate shape: the app just forwards uploads to the grader
TASK_DEF="$(cat <<EOF
{
  "family": "${TASK_FAMILY}",
  "requiresCompatibilities": ["FARGATE"],
  "networkMode": "awsvpc",
  "cpu": "256",
  "memory": "512",
  "taskRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/${SUBMISSION_ROLE}",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE}",
  "containerDefinitions": [
    {
      "name": "web",
      "image": "${IMAGE_URI}",
      "essential": true,
      "portMappings": [{"containerPort": ${PORT}, "protocol": "tcp"}],
      "environment": [{"name": "GRADER_FUNCTION_NAME", "value": "${GRADER_FN}"}],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "web"
        }
      }
    }
  ]
}
EOF
)"
# register creates a new revision each run; create-or-update means latest revision wins
TASK_DEF_ARN="$(aws ecs register-task-definition --cli-input-json "$TASK_DEF" --region "$REGION" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
echo "    registered ${TASK_DEF_ARN}"

# ---------------------------------------------------------------------------
echo "==> [5/6] Service"
NETWORK_CONFIG="awsvpcConfiguration={subnets=[${SUBNET_CSV}],securityGroups=[${SG_ID}],assignPublicIp=ENABLED}"
if aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
    --query "services[?status=='ACTIVE']" --output text | grep -q .; then
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
    --task-definition "$TASK_DEF_ARN" --force-new-deployment \
    --network-configuration "$NETWORK_CONFIG" --region "$REGION" >/dev/null
  echo "    service updated (new deployment rolling out)"
else
  aws ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" \
    --task-definition "$TASK_DEF_ARN" --desired-count 1 --launch-type FARGATE \
    --network-configuration "$NETWORK_CONFIG" --region "$REGION" >/dev/null
  echo "    service created"
fi

echo "    waiting for the task to reach RUNNING"
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION"

# the public IP lives on the task's ENI, not on ECS - hop through EC2 to read it
TASK_ARN="$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
  --desired-status RUNNING --region "$REGION" --query 'taskArns[0]' --output text)"
ENI_ID="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --region "$REGION" \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text)"
PUBLIC_IP="$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --region "$REGION" \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)"
if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
  echo "    ERROR: task is running but has no public IP - check the subnet auto-assigns public IPs." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
echo "==> [6/6] Done."
cat <<EOF

======================================================================
Submission page is live:

    http://${PUBLIC_IP}/

Share that link on competition day. Health check: http://${PUBLIC_IP}/health
Logs: CloudWatch log group ${LOG_GROUP} (${REGION}).

Caveats, eyes open:
  - The IP changes if the task is replaced (redeploy, crash, stop/start).
    Re-run this script to print the fresh IP.
  - HTTP, no TLS, open to the internet. Fine in a room on trust; see README.

When the competition ends, stop the meter: ./kill-web.sh
======================================================================
EOF
