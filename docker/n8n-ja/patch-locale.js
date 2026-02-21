#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const localeFile = process.argv[2];
if (!localeFile) {
  throw new Error("Usage: patch-locale.js <ja-locale-json>");
}

const localeData = JSON.parse(fs.readFileSync(localeFile, "utf8"));

const assetsDir =
  "/usr/local/lib/node_modules/n8n/node_modules/.pnpm/n8n-editor-ui@file+packages+frontend+editor-ui/node_modules/n8n-editor-ui/dist/assets";

const target = fs
  .readdirSync(assetsDir)
  .find((name) => name.startsWith("_MapCache-") && name.endsWith(".js"));

if (!target) {
  throw new Error("Could not find _MapCache asset in " + assetsDir);
}

const targetPath = path.join(assetsDir, target);
let content = fs.readFileSync(targetPath, "utf8");

const markerRegex = /messages:\s*\{\s*en:\s*en_default\s*\},/;
const patchedRegex = /messages:\s*\{\s*en:\s*en_default\s*,\s*ja:/;
if (!markerRegex.test(content) && !patchedRegex.test(content)) {
  throw new Error(`Expected locale marker not found in ${targetPath}`);
}

if (patchedRegex.test(content)) {
  console.log(`Locale already patched: ${targetPath}`);
  process.exit(0);
}

const json = JSON.stringify(localeData)
  .replace(/\u2028/g, "\\u2028")
  .replace(/\u2029/g, "\\u2029");
const replacement =
  `messages: { en: en_default, ja: Object.assign({}, en_default, ${json}) },`;

content = content.replace(markerRegex, replacement);
fs.writeFileSync(targetPath, content, "utf8");

console.log("Patched locale file: " + targetPath);
