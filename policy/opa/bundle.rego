package ai.policy

import rego.v1

# Dynamic allow-list support from policy registry (Phase 1).
# Existing static allowed_task_types in data.policy still works.

task_type_allowed(task_type) if {
  some i
  wf := object.get(data, "policy_registry", {"workflows": []}).workflows[i]
  object.get(wf, "enabled", true)
  object.get(wf, "task_type", "") == task_type
}
