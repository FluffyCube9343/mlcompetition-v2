#submission service: serves the page, validates uploads, invokes the grader

import base64
import json
import os
import re

import boto3
from flask import Flask, jsonify, request, send_file

app = Flask(__name__)

GRADER_FUNCTION_NAME = os.environ["GRADER_FUNCTION_NAME"]

ENTRY_POINT = "main.py"      # the contract: this file is what gets executed
MAX_FILES = 20               # limit files to avoid blowing up storage cost
MAX_FILE_BYTES = 3 * 1024 * 1024
MAX_TOTAL_BYTES = 4 * 1024 * 1024  # dataset + files must fit one 6MB Lambda payload

REFUSED_EXTENSIONS = {".pkl", ".pickle", ".joblib"}  # pickle is code execution

_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")  # flat names only: no folders, no traversal

_lambda = boto3.client("lambda")


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/")
def index():
    return send_file(os.path.join(os.path.dirname(__file__), "index.html"))


def _validate_files(storage_list):  #returns (files, error); files is a list of {"name", "bytes"} dicts
    if not storage_list:
        return None, "no files uploaded"
    if len(storage_list) > MAX_FILES:
        return None, f"too many files (max {MAX_FILES})"

    files = []
    seen = set()
    total = 0
    for storage in storage_list:
        name = storage.filename or ""
        if not _NAME_RE.match(name):
            return None, f"bad filename {name!r} - use a plain file name, no folders"
        if name in seen:
            return None, f"duplicate file: {name}"
        seen.add(name)
        ext = os.path.splitext(name)[1].lower()
        if ext in REFUSED_EXTENSIONS:
            return None, (
                f"{name} is a pickle file, which is refused - pickle can run "
                "arbitrary code at load time. Export weights as .safetensors, "
                ".onnx, or .h5 instead."
            )
        data = storage.read()
        if not data:
            return None, f"{name} is empty"
        if len(data) > MAX_FILE_BYTES:
            return None, f"{name} is too large (max {MAX_FILE_BYTES} bytes per file)"
        total += len(data)
        files.append({"name": name, "bytes": data})

    if ENTRY_POINT not in seen:
        return None, f"{ENTRY_POINT} is required - it is the entry point we run"
    if total > MAX_TOTAL_BYTES:
        return None, (
            f"total upload too large ({total} bytes, max {MAX_TOTAL_BYTES}) - "
            "everything must fit in one Lambda payload"
        )
    return files, None


@app.post("/submit")
def submit():
    # open competition: the team name comes from the form as-is
    team = (request.form.get("team") or "").strip()
    if not team:
        return jsonify({"error": "team name is required"}), 400

    files, error = _validate_files(request.files.getlist("files"))
    if error:
        return jsonify({"error": error}), 400

    # base64 because the Lambda payload is JSON, not bytes
    event = {
        "team": team,
        "files": [
            {"name": f["name"], "b64": base64.b64encode(f["bytes"]).decode()}
            for f in files
        ],
    }

    response = _lambda.invoke(
        FunctionName=GRADER_FUNCTION_NAME,
        InvocationType="RequestResponse",
        Payload=json.dumps(event).encode(),
    )
    result = json.loads(response["Payload"].read())
    if response.get("FunctionError"):
        return jsonify({"error": "grading failed", "detail": result}), 502
    return jsonify(result)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)  # local dev only; the container runs gunicorn
