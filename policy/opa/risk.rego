package ai.policy

import rego.v1

risk_score := network + unknown_task + admin_scope + large_payload

network := 40 if object.get(input.context, "network_enabled", false)
else := 0

unknown_task := 35 if {
	task_type := object.get(input.resource, "task_type", "")
	task_type != ""
	not task_type in data.policy.allowed_task_types
}
else := 0

admin_scope := 10 if startswith(object.get(input.resource, "scope", ""), "admin:")
else := 0

large_payload := 20 if object.get(input.context, "payload_size", 0) > 100000
else := 0
