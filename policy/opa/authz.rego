package ai.policy

import rego.v1

default allow := false
default requires_approval := false

policy_id := "executor-core-v1"
policy_version := "2026-02-20"

decision := "allow" if allow
decision := "requires_approval" if requires_approval
decision := "deny" if {
	not allow
	not requires_approval
}

allow if {
	not deny_task_type
	not deny_scope_mismatch
	not deny_network
	not approval_high_risk
}

requires_approval if approval_high_risk

deny_reasons contains "task_type_not_allowed" if deny_task_type
deny_reasons contains "scope_mismatch" if deny_scope_mismatch
deny_reasons contains "network_not_allowed" if deny_network
deny_reasons contains "high_risk_requires_approval" if approval_high_risk

deny_task_type if {
	input.action == "executor.execute"
	task_type := object.get(input.resource, "task_type", "")
	task_type == ""
}

deny_task_type if {
	input.action == "executor.execute"
	task_type := object.get(input.resource, "task_type", "")
	task_type != ""
	not task_type_allowed(task_type)
}

deny_scope_mismatch if {
	subject_scope := object.get(input.subject, "scope", "")
	resource_scope := object.get(input.resource, "scope", "")
	subject_scope != ""
	resource_scope != ""
	subject_scope != resource_scope
}

deny_network if {
	input.action == "executor.execute"
	object.get(input.context, "network_enabled", false)
	not object.get(input.subject, "network_admin", false)
}

approval_high_risk if {
	risk := data.ai.policy.risk_score
	risk >= data.policy.thresholds.requires_approval
	risk < data.policy.thresholds.deny
}

task_type_allowed(task_type) if task_type in data.policy.allowed_task_types

reasons := sort([r | r := deny_reasons[_]])

result := {
	"policy_id": policy_id,
	"policy_version": policy_version,
	"decision": decision,
	"allow": allow,
	"requires_approval": requires_approval,
	"risk_score": data.ai.policy.risk_score,
	"reasons": reasons,
}
