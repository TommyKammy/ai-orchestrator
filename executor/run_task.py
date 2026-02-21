import json
import sys
import datetime
import os

from policy_client import PolicyClient

ALLOWED_TASK_TYPES = {"ping", "health_check"}
policy_client = PolicyClient()

def main():
    task = json.loads(sys.stdin.read())
    
    task_type = task.get("type")
    policy_result = policy_client.evaluate({
        "subject": {
            "tenant_id": os.environ.get("TENANT_ID", "unknown"),
            "scope": os.environ.get("SCOPE", "unknown"),
            "role": "executor-runner",
        },
        "resource": {
            "task_type": task_type or "",
            "scope": os.environ.get("SCOPE", "unknown"),
        },
        "action": "executor.execute",
        "context": {
            "network_enabled": False,
            "payload_size": len(json.dumps(task)),
        },
    })
    if not policy_client.enforce(policy_result):
        print(json.dumps({
            "timestamp": datetime.datetime.utcnow().isoformat(),
            "error": "Policy denied",
            "policy": policy_result,
        }))
        sys.exit(1)

    if task_type not in ALLOWED_TASK_TYPES:
        error_response = {
            "timestamp": datetime.datetime.utcnow().isoformat(),
            "error": "Task type not allowed",
            "allowed_types": list(ALLOWED_TASK_TYPES),
            "received_type": task_type,
            "policy": policy_result,
        }
        print(json.dumps(error_response))
        sys.exit(1)

    log = {
        "timestamp": datetime.datetime.utcnow().isoformat(),
        "task": task,
        "status": "received",
        "policy": policy_result,
    }

    print(json.dumps(log))

if __name__ == "__main__":
    main()
