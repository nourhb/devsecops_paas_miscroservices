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
function envTrim(map, key) {
    const v = map.get(key);
    if (v == null) {
        return "";
    }
    return String(v).trim();
}
function prometheusNodePortUrl(url) {
    return /:30536\/?$/.test(url) || /:30083\/?$/.test(url);
}
const PROM_IN_CLUSTER = "http://kube-prometheus-stack-prometheus.monitoring.svc:9090";
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
    const dbIdx = entries.findIndex(([k]) => k === "DATABASE_URL");
    if (dbIdx >= 0) {
        const [, v] = entries[dbIdx];
        const k8sDb = v
            .replace("@localhost:5432", "@postgres:5432")
            .replace("@127.0.0.1:5432", "@postgres:5432")
            .replace("@postgres.paas.svc.cluster.local:5432", "@postgres:5432");
        if (k8sDb !== v) {
            console.warn("WARN: DATABASE_URL host adjusted for in-cluster Postgres service");
            byKey.set("DATABASE_URL", k8sDb);
        }
    }
    const labHost = (() => {
        const app = byKey.get("APP_BASE_URL") || byKey.get("NEXT_PUBLIC_APP_BASE_URL") || "";
        const m = String(app).match(/^https?:\/\/([^:/?#]+)/i);
        return m ? m[1] : null;
    })();
    if (labHost && labHost !== "host.docker.internal") {
        for (const [k, v] of [...byKey.entries()]) {
            if (!/_BASE_URL$|_PROBE_URL$/.test(k) || !v.includes("host.docker.internal")) {
                continue;
            }
            const rewritten = v.replace(/host\.docker\.internal/g, labHost);
            if (rewritten !== v) {
                console.warn(`WARN: ${k} host.docker.internal -> ${labHost} for Kubernetes PaaS`);
                byKey.set(k, rewritten);
            }
        }
    }
    const labNodeIp = byKey.get("APPS_PUBLIC_LAB_NODE_IP") || byKey.get("NODE_IP") || labHost || "";
    for (const key of ["PROMETHEUS_PROBE_URL", "PROMETHEUS_BASE_URL"]) {
        const current = envTrim(byKey, key);
        if (current && prometheusNodePortUrl(current)) {
            byKey.set(key, PROM_IN_CLUSTER);
            console.warn(`WARN: ${key} NodePort rewritten to in-cluster ${PROM_IN_CLUSTER} (pods cannot reach node NodePort on this lab)`);
        }
    }
    if (labNodeIp && !envTrim(byKey, "PROMETHEUS_PROBE_URL")) {
        byKey.set("PROMETHEUS_PROBE_URL", PROM_IN_CLUSTER);
        console.warn(`WARN: PROMETHEUS_PROBE_URL defaulted to ${PROM_IN_CLUSTER}`);
    }
    if (labNodeIp && !envTrim(byKey, "PROMETHEUS_BASE_URL")) {
        byKey.set("PROMETHEUS_BASE_URL", PROM_IN_CLUSTER);
        console.warn(`WARN: PROMETHEUS_BASE_URL defaulted to ${PROM_IN_CLUSTER}`);
    }
    const entriesOut = [...byKey.entries()];
    const header = "";
    const body = entriesOut.map(([k, v]) => `${k}=${escapeForComposeLine(v)}`).join("\n");
    writeFileSync(outputPath, `${header}${body}\n`, "utf8");
    console.log(`Wrote ${outputPath} (${entriesOut.length} variables)`);
}
main();
