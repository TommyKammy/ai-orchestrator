import json
import subprocess
import sys

ALLOWED_SCRIPT = "/workspace/run_task.py"
MAX_INPUT_BYTES = 1024 * 1024
PYTHON_BIN = "/usr/local/bin/python"

def main():
    try:
        data = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        if len(data) > MAX_INPUT_BYTES:
            print(json.dumps({"error": "input_too_large", "max_bytes": MAX_INPUT_BYTES}))
            return

        task = json.loads(data.decode("utf-8"))

        proc = subprocess.run(
            [PYTHON_BIN, ALLOWED_SCRIPT],
            input=json.dumps(task).encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )

        result = {
            "exit_code": proc.returncode,
            "stdout": proc.stdout.decode("utf-8", errors="replace"),
            "stderr": proc.stderr.decode("utf-8", errors="replace"),
        }
        print(json.dumps(result))

    except Exception as e:
        print(json.dumps({"error": str(e)}))

if __name__ == "__main__":
    main()
