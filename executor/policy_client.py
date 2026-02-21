"""
Policy client for OPA-based authorization and risk checks.
"""

import json
import os
import urllib.error
import urllib.request
from typing import Any, Dict


class PolicyClient:
    """Small OPA client with mode and failure behavior controls."""

    def __init__(self):
        self.opa_url = os.environ.get("OPA_URL", "http://opa:8181").rstrip("/")
        self.mode = os.environ.get("POLICY_MODE", "shadow").lower()
        self.fail_mode = os.environ.get("POLICY_FAIL_MODE", "open").lower()
        self.timeout_ms = int(os.environ.get("POLICY_TIMEOUT_MS", "800"))
        self.endpoint = f"{self.opa_url}/v1/data/ai/policy/result"

    def evaluate(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        """Evaluate a policy input and normalize response fields."""
        req = urllib.request.Request(
            self.endpoint,
            data=json.dumps({"input": payload}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout_ms / 1000.0) as resp:
                raw = json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            return self._fallback_result(str(exc))

        result = raw.get("result", {})
        if not isinstance(result, dict):
            return self._fallback_result("invalid_policy_response")

        decision = str(result.get("decision", "deny"))
        allow = bool(result.get("allow", decision == "allow"))
        requires_approval = bool(result.get("requires_approval", decision == "requires_approval"))
        reasons = result.get("reasons", [])
        if not isinstance(reasons, list):
            reasons = [str(reasons)]

        normalized = {
            "policy_id": str(result.get("policy_id", "unknown")),
            "policy_version": str(result.get("policy_version", "unknown")),
            "decision": decision,
            "allow": allow,
            "requires_approval": requires_approval,
            "risk_score": int(result.get("risk_score", 0)),
            "reasons": reasons,
            "error": None,
        }
        return normalized

    def enforce(self, result: Dict[str, Any]) -> bool:
        """Return True if request should be allowed to proceed."""
        if self.mode != "enforce":
            return True
        if result.get("allow"):
            return True
        return False

    def _fallback_result(self, error_message: str) -> Dict[str, Any]:
        open_mode = self.fail_mode == "open"
        decision = "allow" if open_mode else "deny"
        return {
            "policy_id": "fallback",
            "policy_version": "fallback",
            "decision": decision,
            "allow": open_mode,
            "requires_approval": False if open_mode else True,
            "risk_score": 0,
            "reasons": ["policy_unavailable"],
            "error": error_message,
        }
