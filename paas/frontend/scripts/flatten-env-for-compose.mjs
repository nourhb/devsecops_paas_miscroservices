#!/usr/bin/env node
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const argIn = process.argv[2];
const argOut = process.argv[3];
const inputPath = argIn ? resolve(process.cwd(), argIn) : join(root, ".env");
const outputPath = argOut ? resolve(process.cwd(), argOut) : join(root, "docker-compose.env");
const KEY_RE = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/;
function parseLooseEnv(text) {
    const lines = text.split(/\r?\n/);
    const out = [];
    let current = null;
    const flush = () => {
        if (!current)
            return;
        out.push([current.key, current.parts.join("\n")]);
        current = null;
    };
    for (const line of lines) {
        const t = line.trimEnd();
        if (/^\s*#/.test(t) || /^\s*$/.test(t)) {
            continue;
        }
        const m = t.match(KEY_RE);
        if (m) {
            flush();
            current = { key: m[1], parts: [m[2] == null ? "" : m[2]] };
            continue;
        }
        if (current) {
            current.parts.push(t);
        }
    }
    flush();
    return out;
}
function escapeForComposeLine(value) {
    const needsQuote = /[\r\n]/.test(value) ||
        /["\\]/.test(value) ||
        /\s/.test(value) ||
        /[#]/.test(value) ||
        /\$/.test(value) ||
        value === "";
    if (!needsQuote) {
        return `${value}`;
    }
    const escaped = value
        .replace(/\\/g, "\\\\")
        .replace(/"/g, '\\"')
        .replace(/\r\n/g, "\n")
        .replace(/\n/g, "\\n")
        .replace(/\r/g, "\\n")
        .replace(/\$/g, "$$$$");
    return `"${escaped}"`;
}
function main() {
    if (!existsSync(inputPath)) {
        console.error(`Missing ${inputPath}; create frontend/.env first.`);
        process.exit(1);
    }
    const text = readFileSync(inputPath, "utf8");
    const parsed = parseLooseEnv(text);
    const byKey = new Map();
    for (const [key, value] of parsed) {
        if (byKey.has(key)) {
            console.warn(`WARN: duplicate ${key} in ${inputPath} — using last value`);
        }
        byKey.set(key, value);
    }
    const entries = [...byKey.entries()];
    const header = "";
    const body = entries.map(([k, v]) => `${k}=${escapeForComposeLine(v)}`).join("\n");
    writeFileSync(outputPath, `${header}${body}\n`, "utf8");
    console.log(`Wrote ${outputPath} (${entries.length} variables)`);
}
main();
