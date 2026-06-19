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
    if (labNodeIp && !envTrim(byKey, "KUBERNETES_ENABLED")) {
        byKey.set("KUBERNETES_ENABLED", "true");
        console.warn("WARN: KUBERNETES_ENABLED defaulted to true for lab");
    }
    const JENKINS_NODEPORT = 30090;
    const isInClusterJenkinsUrl = (url) => {
        const u = String(url || "").trim();
        if (!u) {
            return false;
        }
        return (/jenkins-service|\.svc\.cluster\.local/i.test(u) && !/:30090/i.test(u))
            || /^https?:\/\/10\.\d+\.\d+\.\d+:8080\/?$/i.test(u);
    };
    const jenkinsBase = envTrim(byKey, "JENKINS_BASE_URL") || envTrim(byKey, "JENKINS_URL");
    if (labNodeIp && isInClusterJenkinsUrl(jenkinsBase)) {
        const nodeJenkins = `http://${labNodeIp}:${JENKINS_NODEPORT}`;
        byKey.set("JENKINS_BASE_URL", nodeJenkins);
        if (byKey.has("JENKINS_URL")) {
            byKey.set("JENKINS_URL", nodeJenkins);
        }
        console.warn(`WARN: JENKINS_BASE_URL in-cluster/dead clusterIP -> ${nodeJenkins} (frontend pod uses node NodePort)`);
    }
    const dtBase = envTrim(byKey, "DEPENDENCY_TRACK_BASE_URL");
    const jenkinsDt = envTrim(byKey, "JENKINS_DEPENDENCY_TRACK_BASE_URL");
    if (dtBase && /:\d+/.test(dtBase) && (!jenkinsDt || /\.svc\.cluster\.local/i.test(jenkinsDt))) {
        byKey.set("JENKINS_DEPENDENCY_TRACK_BASE_URL", dtBase);
        console.warn(`WARN: JENKINS_DEPENDENCY_TRACK_BASE_URL -> ${dtBase} (Jenkins built-in uses NodePort, not cluster DNS)`);
    }
    const sonarBase = envTrim(byKey, "SONAR_BASE_URL") || envTrim(byKey, "SONAR_HOST_URL");
    if (labNodeIp && sonarBase && /\.svc\.cluster\.local/i.test(sonarBase)) {
        const sonarNode = `http://${labNodeIp}:30900`;
        byKey.set("SONAR_BASE_URL", sonarNode);
        byKey.set("SONAR_HOST_URL", sonarNode);
        console.warn(`WARN: SONAR_* in-cluster URL -> ${sonarNode} for Jenkins job params`);
    } else if (labNodeIp && !sonarBase) {
        const sonarNode = `http://${labNodeIp}:30900`;
        byKey.set("SONAR_BASE_URL", sonarNode);
        byKey.set("SONAR_HOST_URL", sonarNode);
        console.warn(`WARN: SONAR_BASE_URL defaulted to ${sonarNode}`);
    }
    if (!envTrim(byKey, "HELM_OCI_PLAIN_HTTP")) {
        byKey.set("HELM_OCI_PLAIN_HTTP", "true");
    }
    if (!envTrim(byKey, "HELM_OCI_INSECURE")) {
        byKey.set("HELM_OCI_INSECURE", "true");
    }
    if (!envTrim(byKey, "JENKINS_NPM_SNAPSHOT_MAX_MB")) {
        byKey.set("JENKINS_NPM_SNAPSHOT_MAX_MB", "800");
    }
    const appBase = envTrim(byKey, "APP_BASE_URL");
    if (appBase && !envTrim(byKey, "ZAP_TARGET_URL")) {
        byKey.set("ZAP_TARGET_URL", appBase);
        console.warn(`WARN: ZAP_TARGET_URL defaulted to APP_BASE_URL (${appBase}) for Step 10 DAST`);
    }
    const entriesOut = [...byKey.entries()];
    const header = "";
    const body = entriesOut.map(([k, v]) => `${k}=${escapeForComposeLine(v)}`).join("\n");
    writeFileSync(outputPath, `${header}${body}\n`, "utf8");
    console.log(`Wrote ${outputPath} (${entriesOut.length} variables)`);
}
main();
