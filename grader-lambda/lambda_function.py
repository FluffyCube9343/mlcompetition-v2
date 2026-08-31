#grader: holds the dataset, invokes the runner once, scores, records the best

import csv
import json
import math
import os
import time

from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

RUNNER_FUNCTION_NAME = os.environ["RUNNER_FUNCTION_NAME"]
SCORES_TABLE = os.environ["SCORES_TABLE"]
LABEL_COLUMN = os.environ.get("LABEL_COLUMN", "label")
DATASET_PATH = os.path.join(os.path.dirname(__file__), "dataset.csv")

ENTRY_POINT = "main.py"

# score = MSE * exp(W_RUNTIME*seconds + W_MEMORY*gb + W_SIZE*mb); no free zone
W_RUNTIME_PER_SEC = 0.02
W_MEMORY_PER_GB = 0.05
W_SIZE_PER_MB = 0.01

_lambda = boto3.client("lambda")
_dynamodb = boto3.resource("dynamodb")


def _load_dataset():  #dataset.csv is packaged with this function; labels never leave it
    rows, labels = [], []
    with open(DATASET_PATH, newline="") as f:
        for record in csv.DictReader(f):
            labels.append(float(record.pop(LABEL_COLUMN)))
            rows.append({k: float(v) for k, v in record.items()})
    return rows, labels


def _mse(predictions, labels):
    if len(predictions) != len(labels):
        raise ValueError(
            f"expected {len(labels)} predictions, got {len(predictions)}"
        )
    return sum((p - y) ** 2 for p, y in zip(predictions, labels)) / len(labels)


def _composite_score(mse, runtime_s, memory_mb, submission_bytes):
    exponent = (
        W_RUNTIME_PER_SEC * runtime_s
        + W_MEMORY_PER_GB * (memory_mb / 1024.0)
        + W_SIZE_PER_MB * (submission_bytes / 1_000_000.0)
    )
    return mse * math.exp(exponent)


def _to_decimal(obj):  #dynamo refuses floats; round-trip through json to decimalize everything
    return json.loads(json.dumps(obj), parse_float=Decimal)


def _record_best_score(team, score, breakdown):  #conditional write: only overwrite a worse (higher) stored score
    table = _dynamodb.Table(SCORES_TABLE)
    try:
        table.put_item(
            Item=_to_decimal({
                "team": team,
                "score": score,
                "breakdown": breakdown,
                "updated_at": int(time.time()),
            }),
            ConditionExpression="attribute_not_exists(team) OR score < :new",
            ExpressionAttributeValues=_to_decimal({":new": score}),
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False  # existing best is still better
        raise


def handler(event, context):
    team = event["team"]
    files = event["files"]  # [{"name", "b64"}], validated upstream

    # don't trust the caller: the grader is the trust boundary for the runner
    if not any(f["name"] == ENTRY_POINT for f in files):
        raise ValueError(f"submission must include {ENTRY_POINT}")

    rows, labels = _load_dataset()

    # one invoke; dataset + files must fit the 6MB payload cap (see README)
    payload = {"files": files, "rows": rows}

    start = time.time()
    response = _lambda.invoke(
        FunctionName=RUNNER_FUNCTION_NAME,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload).encode(),
    )
    runtime_s = time.time() - start

    result = json.loads(response["Payload"].read())
    if response.get("FunctionError"):
        raise RuntimeError(f"runner failed: {result.get('errorMessage', result)}")

    predictions = result["predictions"]
    memory_mb = result["peak_memory_mb"]
    mse = _mse(predictions, labels)

    # size term counts the whole submission, script + weights + helpers
    submission_bytes = sum(len(f["b64"]) for f in files)
    score = _composite_score(mse, runtime_s, memory_mb, submission_bytes)

    breakdown = {
        "mse": round(mse, 6),
        "runtime_s": round(runtime_s, 3),
        "peak_memory_mb": memory_mb,
        "submission_bytes": submission_bytes,
    }
    is_best = _record_best_score(team, score, breakdown)

    return {
        "team": team,
        "score": round(score, 6),
        "new_best": is_best,
        **breakdown,
    }
