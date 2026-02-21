#!/usr/bin/env python3
import io
import json
import os
import tarfile
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

POLICY_SOURCE_DIR = os.environ.get("POLICY_SOURCE_DIR", "/policy-source")
POLICY_RUNTIME_DIR = os.environ.get("POLICY_RUNTIME_DIR", "/policy-runtime")
RUNTIME_REGISTRY_PATH = os.path.join(POLICY_RUNTIME_DIR, "policy_registry.json")
HOST = os.environ.get("BUNDLE_SERVER_HOST", "0.0.0.0")
PORT = int(os.environ.get("BUNDLE_SERVER_PORT", "8088"))


def _read_text(path, fallback=""):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return fallback


def _read_json(path, fallback):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return fallback


def build_bundle_bytes():
    data = _read_json(os.path.join(POLICY_SOURCE_DIR, "data.json"), {"policy": {}})
    data.setdefault("policy", {})
    data.setdefault("policy_registry", {"workflows": []})
    data.setdefault("bundle_meta", {})
    runtime_registry = _read_json(RUNTIME_REGISTRY_PATH, {})
    if isinstance(runtime_registry.get("workflows"), list):
        data["policy_registry"]["workflows"] = runtime_registry["workflows"]
    if runtime_registry.get("revision_id"):
        data["bundle_meta"]["revision_id"] = runtime_registry["revision_id"]
    if runtime_registry.get("published_at"):
        data["bundle_meta"]["published_at"] = runtime_registry["published_at"]
    if runtime_registry.get("actor"):
        data["bundle_meta"]["actor"] = runtime_registry["actor"]
    data["bundle_meta"]["generated_at"] = datetime.now(timezone.utc).isoformat()

    rego_files = [
        "authz.rego",
        "risk.rego",
        "bundle.rego",
    ]

    mem = io.BytesIO()
    with tarfile.open(fileobj=mem, mode="w:gz") as tar:
        for name in rego_files:
            content = _read_text(os.path.join(POLICY_SOURCE_DIR, name), "")
            if not content:
                continue
            blob = content.encode("utf-8")
            info = tarfile.TarInfo(name=f"policy/{name}")
            info.size = len(blob)
            tar.addfile(info, io.BytesIO(blob))

        data_blob = json.dumps(data, ensure_ascii=True, indent=2).encode("utf-8")
        data_info = tarfile.TarInfo(name="data.json")
        data_info.size = len(data_blob)
        tar.addfile(data_info, io.BytesIO(data_blob))

    mem.seek(0)
    return mem.read()


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "11")
            self.end_headers()
            return

        if self.path == "/bundles/policy.tar.gz":
            body = build_bundle_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/gzip")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return

        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        if self.path == "/healthz":
            self._send_json(200, {"ok": True})
            return

        if self.path == "/bundles/policy.tar.gz":
            body = build_bundle_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/gzip")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/registry/current":
            payload = _read_json(RUNTIME_REGISTRY_PATH, {"workflows": []})
            if "workflows" not in payload:
                payload["workflows"] = []
            self._send_json(200, payload)
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path != "/registry/publish":
            self.send_response(404)
            self.end_headers()
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"ok": False, "error": "invalid content-length"})
            return

        raw_body = self.rfile.read(content_length)
        try:
            payload = json.loads(raw_body.decode("utf-8") if raw_body else "{}")
        except Exception:
            self._send_json(400, {"ok": False, "error": "invalid json"})
            return

        workflows = payload.get("workflows")
        if not isinstance(workflows, list):
            self._send_json(400, {"ok": False, "error": "workflows must be array"})
            return

        runtime_payload = {
            "revision_id": str(payload.get("revision_id", "")).strip() or f"rev-{int(datetime.now(timezone.utc).timestamp())}",
            "actor": str(payload.get("actor", "n8n-ce")),
            "notes": str(payload.get("notes", "")),
            "published_at": datetime.now(timezone.utc).isoformat(),
            "workflows": workflows,
        }

        Path(POLICY_RUNTIME_DIR).mkdir(parents=True, exist_ok=True)
        tmp_path = f"{RUNTIME_REGISTRY_PATH}.tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(runtime_payload, f, ensure_ascii=True, indent=2)
            f.write("\n")
        os.replace(tmp_path, RUNTIME_REGISTRY_PATH)

        self._send_json(200, {"ok": True, "revision_id": runtime_payload["revision_id"], "count": len(workflows)})

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), Handler)
    server.serve_forever()
