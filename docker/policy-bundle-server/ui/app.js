const $ = (s) => document.querySelector(s);
const ruleTable = $("#ruleTable");
const ruleCount = $("#ruleCount");
const runtimeBox = $("#runtimeBox");
const resultBox = $("#resultBox");
const searchText = $("#searchText");
const filterEnabled = $("#filterEnabled");

let allRules = [];

function setResult(data) {
  resultBox.textContent = JSON.stringify(data, null, 2);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function escapeHtml(v = "") {
  return String(v)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function ruleMatch(rule) {
  const q = (searchText?.value || "").trim().toLowerCase();
  const enabledFilter = filterEnabled?.value || "all";

  if (enabledFilter === "true" && !rule.enabled) return false;
  if (enabledFilter === "false" && rule.enabled) return false;

  if (!q) return true;
  const hay = `${rule.workflow_id || ""} ${rule.task_type || ""} ${rule.scope_pattern || ""}`.toLowerCase();
  return hay.includes(q);
}

function renderRules() {
  const rows = allRules.filter(ruleMatch);
  ruleCount.textContent = String(rows.length);

  ruleTable.innerHTML = rows
    .map((r) => {
      const badgeClass = r.enabled ? "status-on" : "status-off";
      const badgeText = r.enabled ? "enabled" : "disabled";
      const ruleKey = encodeURIComponent(`${r.workflow_id || ""}|||${r.task_type || ""}`);

      return `<tr>
        <td>${escapeHtml(r.workflow_id)}</td>
        <td>${escapeHtml(r.task_type)}</td>
        <td><span class="status-pill ${badgeClass}">${badgeText}</span></td>
        <td>${escapeHtml(r.updated_at || "")}</td>
        <td><button class="btn btn-ghost" data-rule-key="${ruleKey}">inspect</button></td>
      </tr>`;
    })
    .join("");

  ruleTable.querySelectorAll("button[data-rule-key]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      try {
        const [wf, task] = decodeURIComponent(btn.dataset.ruleKey || "").split("|||");
        const detail = await apiGet(`/policy-ui/api/get?workflow_id=${encodeURIComponent(wf || "")}&task_type=${encodeURIComponent(task || "")}`);
        const row = detail.item || allRules.find((x) => x.workflow_id === wf && x.task_type === task) || {};

        const form = $("#upsertForm");
        form.task_type.value = row.task_type || "";
        form.policy_scope.value = row.workflow_id && row.workflow_id !== "*" ? "workflow_and_task" : "task_type_only";
        form.workflow_id.value = row.workflow_id && row.workflow_id !== "*" ? row.workflow_id : "";
        form.tenant_id.value = row.tenant_id || "*";
        form.scope_pattern.value = row.scope_pattern || "*";
        form.enabled.value = row.enabled ? "true" : "false";
        form.constraints.value = JSON.stringify(row.constraints_jsonb || {}, null, 2);
        setResult({ ok: true, action: "inspect", item: row });
      } catch (err) {
        setResult({ ok: false, action: "inspect", error: err });
      }
    });
  });
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
  allRules = Array.isArray(data.items) ? data.items : [];
  renderRules();
}

async function loadRuntime() {
  const data = await apiGet("/policy-ui/api/current");
  runtimeBox.textContent = JSON.stringify(data, null, 2);
  return data;
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
    task_type: f.task_type.value.trim(),
    policy_scope: f.policy_scope.value || "task_type_only",
    workflow_id: f.workflow_id.value.trim() || "*",
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

  const payload = {
    revision_id: f.revision_id.value.trim(),
    actor: f.actor.value.trim() || "policy-ui",
    notes: f.notes.value.trim(),
  };

  try {
    const [current, listData] = await Promise.all([
      apiGet("/policy-ui/api/current"),
      apiGet("/policy-ui/api/list"),
    ]);

    const items = Array.isArray(listData.items) ? listData.items : [];
    const enabledCount = items.filter((x) => x.enabled).length;
    const msg = [
      `Current revision: ${current.revision_id || "(none)"}`,
      `Next revision: ${payload.revision_id}`,
      `Enabled rules: ${enabledCount}`,
      "",
      "Publish to runtime registry?",
    ].join("\n");

    if (!confirm(msg)) return;

    const result = await apiPost("/policy-ui/api/publish", payload);

    // Reflection check (OPA polling interval is up to 30 seconds)
    let reflected = false;
    let reflectedAt = null;
    let latest = null;
    for (let i = 0; i < 6; i += 1) {
      latest = await loadRuntime();
      if ((latest.revision_id || "") === payload.revision_id) {
        reflected = true;
        reflectedAt = new Date().toISOString();
        break;
      }
      await sleep(5000);
    }

    setResult({
      ok: true,
      action: "publish",
      request: payload,
      publish: result,
      reflection: {
        reflected,
        reflectedAt,
        currentRevision: latest?.revision_id || null,
      },
    });
  } catch (err) {
    setResult({ ok: false, action: "publish", error: err });
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

[searchText, filterEnabled].forEach((el) => {
  el?.addEventListener("input", renderRules);
  el?.addEventListener("change", renderRules);
});

(async () => {
  try {
    await Promise.all([loadRules(), loadRuntime()]);
    setResult({ ok: true, message: "ready" });
  } catch (err) {
    setResult(err);
  }
})();
