#!/usr/bin/env python3
import io
import json
import os
import tarfile
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

POLICY_SOURCE_DIR = os.environ.get("POLICY_SOURCE_DIR", "/policy-source")
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
    def do_GET(self):
        if self.path == "/healthz":
            payload = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
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

        self.send_response(404)
        self.end_headers()

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), Handler)
    server.serve_forever()
