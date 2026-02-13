import json
import sys
import datetime

ALLOWED_TASK_TYPES = {"ping", "health_check"}

def main():
    task = json.loads(sys.stdin.read())
    
    task_type = task.get("type")
    if task_type not in ALLOWED_TASK_TYPES:
        error_response = {
            "timestamp": datetime.datetime.utcnow().isoformat(),
            "error": "Task type not allowed",
            "allowed_types": list(ALLOWED_TASK_TYPES),
            "received_type": task_type
        }
        print(json.dumps(error_response))
        sys.exit(1)

    log = {
        "timestamp": datetime.datetime.utcnow().isoformat(),
        "task": task,
        "status": "received"
    }

    print(json.dumps(log))

if __name__ == "__main__":
    main()
