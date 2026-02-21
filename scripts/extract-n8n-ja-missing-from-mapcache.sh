#!/usr/bin/env bash
set -euo pipefail

# Extract untranslated keys from n8n editor-ui _MapCache in a Docker image.
# Requires Docker; does not require Node.js on the host.
#
# Usage:
#   scripts/extract-n8n-ja-missing-from-mapcache.sh [image] [output]
#
# Example:
#   scripts/extract-n8n-ja-missing-from-mapcache.sh ai-n8n-ja:2.8.3 n8n/locales/ja.missing.from-mapcache.json

IMAGE="${1:-ai-n8n-ja:2.8.3}"
OUTPUT="${2:-n8n/locales/ja.missing.from-mapcache.json}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

docker run --rm \
  -v "$ROOT_DIR:/workspace" \
  -e "OUT_PATH=$OUTPUT" \
  --entrypoint node \
  "$IMAGE" \
  -e '
const fs = require("fs");
const path = require("path");

const workspace = "/workspace";
const jaPath = path.join(workspace, "n8n/locales/ja.partial.json");
const outPath = path.join(workspace, process.env.OUT_PATH);

const assetsDir = "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/n8n-editor-ui@file+packages+frontend+editor-ui/node_modules/n8n-editor-ui/dist/assets";
const target = fs.readdirSync(assetsDir).find((n) => n.startsWith("_MapCache-") && n.endsWith(".js"));
if (!target) throw new Error("Could not find _MapCache asset in " + assetsDir);

const content = fs.readFileSync(path.join(assetsDir, target), "utf8");
const ja = JSON.parse(fs.readFileSync(jaPath, "utf8"));

// Collect first-seen key/value pairs from translation map literals.
// Keep only i18n-looking keys (namespace.key).
const all = {};
const re = /"([A-Za-z0-9_-]+(?:\.[^"\n]+)+)"\s*:\s*"([^"\n]*)"/g;
let m;
while ((m = re.exec(content)) !== null) {
  const key = m[1];
  const val = m[2];
  if (!(key in all)) all[key] = val;
}

const missing = {};
for (const key of Object.keys(all).sort()) {
  if (!(key in ja)) missing[key] = all[key];
}

fs.writeFileSync(outPath, JSON.stringify(missing, null, 2) + "\n", "utf8");
console.log("MapCache file:", target);
console.log("Known ja keys:", Object.keys(ja).length);
console.log("Missing keys:", Object.keys(missing).length);
console.log("Wrote:", outPath);
'
