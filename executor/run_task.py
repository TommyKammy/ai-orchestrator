import json
import sys
import datetime

def main():
    task = json.loads(sys.stdin.read())

    log = {
        "timestamp": datetime.datetime.utcnow().isoformat(),
        "task": task,
        "status": "received"
    }

    print(json.dumps(log))

if __name__ == "__main__":
    main()
