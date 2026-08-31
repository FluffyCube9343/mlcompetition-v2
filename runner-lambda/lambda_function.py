#this stages/runs the program submission: files land in /tmp/submission, main.py gets exec'd
#assumes readData(row) exists; loadModel(base_dir) is optional but should be there to load a model if needed
#main.py runs with the submission dir as cwd, so siblings open by plain name

import base64
import math
import os
import re
import resource
import shutil
import signal
import sys

WORKDIR = "/tmp/submission"
ENTRY_POINT = "main.py"

MAX_SECONDS_PER_ROW = 5          # per-row guard so a slow loop can't eat the whole timeout
MAX_PREDICTIONS = 1_000_000      # sanity cap on dataset size
MAX_FILES = 20
REFUSED_EXTENSIONS = {".pkl", ".pickle", ".joblib"}  # pickle = code execution
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


#one readData(row) call exceeded MAX_SECONDS_PER_ROW
class RowTimeout(Exception):
    pass


def _alarm_handler(signum, frame):
    raise RowTimeout()


def _peak_memory_mb():
    # ru_maxrss is kilobytes on Linux
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0


def _stage_files(files):  #write the submission into a fresh working directory, return main.py's path
    if len(files) > MAX_FILES:
        raise ValueError(f"too many files (max {MAX_FILES})")

    # warm containers reuse /tmp - wipe the last team's files
    shutil.rmtree(WORKDIR, ignore_errors=True)
    os.makedirs(WORKDIR)

    names = set()
    for f in files:
        name = f["name"]
        if not _NAME_RE.match(name):
            raise ValueError(f"bad filename {name!r}")
        if name in names:
            raise ValueError(f"duplicate file: {name}")
        names.add(name)
        if os.path.splitext(name)[1].lower() in REFUSED_EXTENSIONS:
            raise ValueError(f"{name}: pickle files are refused")
        with open(os.path.join(WORKDIR, name), "wb") as out:
            out.write(base64.b64decode(f["b64"]))

    if ENTRY_POINT not in names:
        raise ValueError(f"submission must include {ENTRY_POINT}")
    return os.path.join(WORKDIR, ENTRY_POINT)


def _load_submission(main_path):  #exec main.py (cwd = submission dir, sibling imports work) and return readData
    os.chdir(WORKDIR)
    if WORKDIR not in sys.path:
        sys.path.insert(0, WORKDIR)

    with open(main_path, "r", encoding="utf-8") as f:
        source = f.read()

    # __name__ = "__main__" so scripts behave like `python main.py`
    namespace = {"__name__": "__main__", "__file__": main_path}
    exec(compile(source, main_path, "exec"), namespace)

    load_model = namespace.get("loadModel")
    if callable(load_model):
        load_model(WORKDIR)

    read_data = namespace.get("readData")
    if not callable(read_data):
        raise ValueError("main.py must define a callable readData(row)")
    return read_data


def handler(event, context):
    rows = event["rows"]  # features only, never labels
    if len(rows) > MAX_PREDICTIONS:
        raise ValueError("row count exceeds sanity cap")

    main_path = _stage_files(event["files"])
    read_data = _load_submission(main_path)

    # per-row alarm: a fairness guard, not the isolation boundary
    signal.signal(signal.SIGALRM, _alarm_handler)
    predictions = []
    for row in rows:
        signal.alarm(MAX_SECONDS_PER_ROW)
        try:
            value = float(read_data(row))
        finally:
            signal.alarm(0)
        if not math.isfinite(value):
            raise ValueError("readData returned a non-finite score")
        predictions.append(value)

    return {
        "predictions": predictions,
        "peak_memory_mb": round(_peak_memory_mb(), 2),
    }
