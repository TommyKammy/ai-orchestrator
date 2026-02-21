package ai.policy

import rego.v1

# Dynamic allow-list support from policy registry (Phase 1).
# Existing static allowed_task_types in data.policy still works.

task_type_allowed(task_type) if {
  some wf in object.get(data.policy_registry, "workflows", [])
  object.get(wf, "enabled", true)
  object.get(wf, "task_type", "") == task_type
}
