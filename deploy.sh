#!/usr/bin/env bash
#
# deploy.sh - stand up the competition-v2 infrastructure on AWS.
# Idempotent: every step is create-or-update, safe to re-run.
#
# Usage:
#   ./deploy.sh                 # deploy to us-east-1
#   REGION=us-west-2 ./deploy.sh
#
# Not done here on purpose (decisions, not defaults - see README):
#   - VPC-locking the runner (console step)
#   - the web tier lives in deploy-web.sh, not here

set -euo pipefail

cd "$(dirname "$0")"  # behave the same no matter where it is invoked from

REGION="${REGION:-us-east-1}"

# fixed names: env vars and IAM policies reference these exact strings
TABLE_NAME="competition-scores"
ECR_REPO="competition-runner"
RUNNER_FN="competition-runner"
GRADER_FN="competition-grader"
RUNNER_ROLE="competition-runner-role"
GRADER_ROLE="competition-grader-role"
SUBMISSION_ROLE="competition-submission-role"

echo "==> Resolving AWS account"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:latest"
echo "    account: ${ACCOUNT_ID}  region: ${REGION}"

# ---------------------------------------------------------------------------
echo "==> [1/6] DynamoDB table: ${TABLE_NAME}"
# one row per team and nothing else to query: hash key only, pay-per-request
if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "    table already exists - keeping it (scores are data, not config)"
else
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=team,AttributeType=S \
    --key-schema AttributeName=team,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
  echo "    created"
fi

# ---------------------------------------------------------------------------
echo "==> [2/6] ECR repo + runner image"
# the runner needs numpy/safetensors, past the 250MB zip limit, so it ships as an image
if ! aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "$ECR_REPO" --region "$REGION" >/dev/null
  echo "    repo created"
else
  echo "    repo already exists"
fi

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# force x86_64: a plain build on Apple Silicon produces an image Lambda cannot run
docker build --provenance=false --sbom=false --platform linux/amd64 -t "${ECR_REPO}:latest" runner-lambda/
docker tag "${ECR_REPO}:latest" "$IMAGE_URI"
docker push "$IMAGE_URI"
echo "    pushed ${IMAGE_URI}"

# ---------------------------------------------------------------------------
echo "==> [3/6] IAM roles (the security model - the why is in README.md)"
# runner: logs only. grader: invoke runner + PutItem scores. submission: invoke grader.
# policies mirror README.md - change both or neither.

LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
# the submission service may run as an ECS task or a plain EC2 instance
SUBMISSION_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["ecs-tasks.amazonaws.com","ec2.amazonaws.com"]},"Action":"sts:AssumeRole"}]}'

create_role_if_missing() {
  local role="$1" trust="$2"
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    echo "    role ${role} already exists"
  else
    aws iam create-role --role-name "$role" --assume-role-policy-document "$trust" >/dev/null
    echo "    role ${role} created"
  fi
}

create_role_if_missing "$RUNNER_ROLE" "$LAMBDA_TRUST"
# the runner holds no keys at all - this line IS the sandbox, keep it this way
aws iam attach-role-policy \
  --role-name "$RUNNER_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

create_role_if_missing "$GRADER_ROLE" "$LAMBDA_TRUST"
# put-role-policy is an upsert, so re-running converges the policy
GRADER_POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], "Resource": "arn:aws:logs:*:*:*"},
    {"Effect": "Allow", "Action": "lambda:InvokeFunction", "Resource": "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${RUNNER_FN}"},
    {"Effect": "Allow", "Action": "dynamodb:PutItem", "Resource": "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"}
  ]
}
EOF
)"
aws iam put-role-policy --role-name "$GRADER_ROLE" --policy-name grader-policy --policy-document "$GRADER_POLICY"

create_role_if_missing "$SUBMISSION_ROLE" "$SUBMISSION_TRUST"
SUBMISSION_POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "lambda:InvokeFunction", "Resource": "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${GRADER_FN}"}
  ]
}
EOF
)"
aws iam put-role-policy --role-name "$SUBMISSION_ROLE" --policy-name submission-policy --policy-document "$SUBMISSION_POLICY"

# IAM propagation is eventually consistent; a fresh role fails with "cannot be assumed"
echo "    waiting 10s for IAM propagation"
sleep 10

# ---------------------------------------------------------------------------
echo "==> [4/6] Runner Lambda: ${RUNNER_FN} (container image)"
# 1GB memory (memory sizes CPU too), 15 min timeout for a full dataset pass
RUNNER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${RUNNER_ROLE}"
if aws lambda get-function --function-name "$RUNNER_FN" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$RUNNER_FN" --image-uri "$IMAGE_URI" --region "$REGION" >/dev/null
  # Lambda rejects a config update while a code update is still in progress
  aws lambda wait function-updated --function-name "$RUNNER_FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$RUNNER_FN" \
    --memory-size 1024 --timeout 900 --role "$RUNNER_ROLE_ARN" --region "$REGION" >/dev/null
  echo "    updated from ${IMAGE_URI}"
else
  aws lambda create-function \
    --function-name "$RUNNER_FN" \
    --package-type Image \
    --code ImageUri="$IMAGE_URI" \
    --role "$RUNNER_ROLE_ARN" \
    --memory-size 1024 \
    --timeout 900 \
    --region "$REGION" >/dev/null
  echo "    created from ${IMAGE_URI}"
fi
aws lambda wait function-active --function-name "$RUNNER_FN" --region "$REGION"

# ---------------------------------------------------------------------------
echo "==> [5/6] Grader Lambda: ${GRADER_FN} (zip)"
# dataset.csv is the held-out labels, intentionally not committed - drop it in first
if [ ! -f grader-lambda/dataset.csv ]; then
  echo "    ERROR: grader-lambda/dataset.csv is missing." >&2
  echo "    Drop your dataset (with a 'label' column) into grader-lambda/ and re-run." >&2
  exit 1
fi

GRADER_ZIP="${PWD}/grader-function.zip"
rm -f "$GRADER_ZIP"
if command -v zip >/dev/null 2>&1; then
  (cd grader-lambda && zip -qr "$GRADER_ZIP" .)
else
  # minimal images may lack zip; python's shutil does the job
  python3 -c "import shutil; shutil.make_archive('${GRADER_ZIP%.zip}', 'zip', 'grader-lambda')"
fi

GRADER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${GRADER_ROLE}"
GRADER_ENV="Variables={RUNNER_FUNCTION_NAME=${RUNNER_FN},SCORES_TABLE=${TABLE_NAME}}"
if aws lambda get-function --function-name "$GRADER_FN" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$GRADER_FN" --zip-file "fileb://${GRADER_ZIP}" --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$GRADER_FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$GRADER_FN" \
    --environment "$GRADER_ENV" --role "$GRADER_ROLE_ARN" --timeout 900 --region "$REGION" >/dev/null
  echo "    updated"
else
  # 512MB: the grader is I/O-bound waiting on the runner; timeout matches the runner
  aws lambda create-function \
    --function-name "$GRADER_FN" \
    --runtime python3.12 \
    --handler lambda_function.handler \
    --role "$GRADER_ROLE_ARN" \
    --zip-file "fileb://${GRADER_ZIP}" \
    --memory-size 512 \
    --timeout 900 \
    --environment "$GRADER_ENV" \
    --region "$REGION" >/dev/null
  echo "    created"
fi
aws lambda wait function-active --function-name "$GRADER_FN" --region "$REGION"
rm -f "$GRADER_ZIP"

# ---------------------------------------------------------------------------
echo "==> [6/6] Done."
cat <<EOF

======================================================================
Deploy complete. Two steps remain - they are console/console-adjacent
by design, because they are decisions, not defaults:

1. VPC-LOCK THE RUNNER (the second half of the sandbox)
   Lambda console -> ${RUNNER_FN} -> Configuration -> VPC -> Edit.
   Attach a VPC with a PRIVATE SUBNET THAT HAS NO INTERNET ROUTE
   (no NAT gateway, no route to an IGW). The IAM role already denies
   every AWS API; this denies the network itself, so participant code
   cannot exfiltrate the dataset or phone home even if it tries.
   (Note: a Lambda in a VPC loses outbound internet by default here -
   that is the point. The runner needs nothing off-box.)

2. DEPLOY THE SUBMISSION SERVICE (submission-service/)
   Just run ./deploy-web.sh - it puts the service on ECS Fargate with
   a public IP, using ${SUBMISSION_ROLE} (invoke grader ONLY) and
   env GRADER_FUNCTION_NAME=${GRADER_FN}, and prints the URL.
   The competition runs OPEN: the page's team-name field is trusted
   as-is. Fine for an in-person event; not for the open internet.

TEST THE GRADER NOW (once dataset.csv is deployed), from the repo root:

  PAYLOAD=\$(python3 -c '
import base64, json
files = [{"name": n, "b64": base64.b64encode(open("examples/" + n, "rb").read()).decode()}
         for n in ("main.py", "coefficients.json")]
print(json.dumps({"team": "smoke-test", "files": files}))
')
  aws lambda invoke \\
    --function-name ${GRADER_FN} \\
    --region ${REGION} \\
    --cli-binary-format raw-in-base64-out \\
    --payload "\$PAYLOAD" \\
    /tmp/grader-result.json && cat /tmp/grader-result.json

  Expect a JSON body with team, score, new_best, mse, runtime_s,
  peak_memory_mb, submission_bytes.

To tear everything this script created down: ./killall.sh
======================================================================
EOF
