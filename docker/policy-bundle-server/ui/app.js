const $ = (s) => document.querySelector(s);
const ruleTable = $("#ruleTable");
const ruleCount = $("#ruleCount");
const runtimeBox = $("#runtimeBox");
const resultBox = $("#resultBox");

function setResult(data) {
  resultBox.textContent = JSON.stringify(data, null, 2);
}

function escapeHtml(v = "") {
  return String(v)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

async function apiGet(path) {
  const res = await fetch(path, { credentials: "same-origin" });
  const json = await res.json().catch(() => ({ error: "invalid json response" }));
  if (!res.ok) throw json;
  return json;
}

async function apiPost(path, payload) {
  const res = await fetch(path, {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const json = await res.json().catch(() => ({ error: "invalid json response" }));
  if (!res.ok) throw json;
  return json;
}

async function loadRules() {
  const data = await apiGet("/policy-ui/api/list");
  const items = Array.isArray(data.items) ? data.items : [];
  ruleCount.textContent = String(items.length);
  ruleTable.innerHTML = items
    .map((r) => {
      const badgeClass = r.enabled ? "status-on" : "status-off";
      const badgeText = r.enabled ? "enabled" : "disabled";
      return `<tr>
        <td>${escapeHtml(r.workflow_id)}</td>
        <td>${escapeHtml(r.task_type)}</td>
        <td><span class="status-pill ${badgeClass}">${badgeText}</span></td>
        <td>${escapeHtml(r.updated_at || "")}</td>
        <td><button class="btn btn-ghost" data-rule='${escapeHtml(JSON.stringify(r))}'>fill</button></td>
      </tr>`;
    })
    .join("");

  ruleTable.querySelectorAll("button[data-rule]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const row = JSON.parse(btn.dataset.rule || "{}");
      const form = $("#upsertForm");
      form.workflow_id.value = row.workflow_id || "";
      form.task_type.value = row.task_type || "";
      form.tenant_id.value = row.tenant_id || "*";
      form.scope_pattern.value = row.scope_pattern || "*";
      form.enabled.value = row.enabled ? "true" : "false";
      form.constraints.value = JSON.stringify(row.constraints_jsonb || {}, null, 2);
    });
  });
}

async function loadRuntime() {
  const data = await apiGet("/policy-ui/api/current");
  runtimeBox.textContent = JSON.stringify(data, null, 2);
}

$("#upsertForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.currentTarget;
  let constraints = {};
  try {
    constraints = JSON.parse(f.constraints.value || "{}");
  } catch {
    setResult({ ok: false, error: "constraints must be valid JSON" });
    return;
  }

  const payload = {
    workflow_id: f.workflow_id.value.trim(),
    task_type: f.task_type.value.trim(),
    tenant_id: f.tenant_id.value.trim() || "*",
    scope_pattern: f.scope_pattern.value.trim() || "*",
    actor: f.actor.value.trim() || "policy-ui",
    enabled: f.enabled.value === "true",
    constraints,
  };

  try {
    const result = await apiPost("/policy-ui/api/upsert", payload);
    setResult(result);
    await loadRules();
  } catch (err) {
    setResult(err);
  }
});

$("#publishForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.currentTarget;
  if (!confirm("Publish this revision to runtime policy registry?")) return;

  const payload = {
    revision_id: f.revision_id.value.trim(),
    actor: f.actor.value.trim() || "policy-ui",
    notes: f.notes.value.trim(),
  };

  try {
    const result = await apiPost("/policy-ui/api/publish", payload);
    setResult(result);
    await loadRuntime();
  } catch (err) {
    setResult(err);
  }
});

$("#refreshCurrent").addEventListener("click", async () => {
  try {
    await loadRuntime();
  } catch (err) {
    setResult(err);
  }
});

$("#refreshAll").addEventListener("click", async () => {
  try {
    await Promise.all([loadRules(), loadRuntime()]);
  } catch (err) {
    setResult(err);
  }
});

(async () => {
  try {
    await Promise.all([loadRules(), loadRuntime()]);
    setResult({ ok: true, message: "ready" });
  } catch (err) {
    setResult(err);
  }
})();
