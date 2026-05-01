#!/usr/bin/env node
import fs from "fs";
import net from "net";
import path from "path";
import { spawnSync } from "child_process";
import { fileURLToPath } from "url";
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const envPath = path.join(__dirname, "..", ".env");
function loadEnv(file) {
    const raw = fs.readFileSync(file, "utf8");
    const env = { ...process.env };
    for (const line of raw.split(/\r?\n/)) {
        const t = line.trim();
        if (!t || t.startsWith("#"))
            continue;
        const eq = t.indexOf("=");
        if (eq === -1)
            continue;
        const k = t.slice(0, eq).trim();
        let v = t.slice(eq + 1).trim();
        if ((v.startsWith('"') && v.endsWith('"')) ||
            (v.startsWith("'") && v.endsWith("'"))) {
            v = v.slice(1, -1);
        }
        env[k] = v;
    }
    return env;
}
function probeTcp(host, port, ms = 5000) {
    return new Promise((resolve) => {
        const s = net.createConnection({ host, port }, () => {
            s.end();
            resolve({ ok: true });
        });
        s.on("error", () => resolve({ ok: false, err: "connect refused / DNS" }));
        s.setTimeout(ms, () => {
            s.destroy();
            resolve({ ok: false, err: "timeout" });
        });
    });
}
async function probeFetch(url, opts = {}) {
    const c = new AbortController();
    const t = setTimeout(() => c.abort(), opts.timeoutMs ?? 10000);
    try {
        const r = await fetch(url, {
            method: opts.method ?? "GET",
            headers: opts.headers ?? {},
            signal: c.signal,
            redirect: opts.redirect ?? "follow"
        });
        clearTimeout(t);
        const text = opts.readBody ? await r.text() : "";
        return {
            ok: opts.accept?.(r.status) ?? (r.ok || r.status === 302),
            status: r.status,
            snippet: text.slice(0, 120)
        };
    }
    catch (e) {
        clearTimeout(t);
        const cause = e.cause?.code || e.cause?.message || e.message;
        return { ok: false, err: String(cause) };
    }
}
function isPlaceholder(v) {
    if (!v || !String(v).trim())
        return true;
    const s = String(v).toLowerCase();
    return (s.includes("your-") ||
        s.includes("changeme") ||
        s === "xxx" ||
        s.includes("example.com"));
}
const env = loadEnv(envPath);
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
const rows = [];
function add(name, status, detail = "") {
    rows.push({ name, status, detail });
}
function basicAuth(user, token) {
    return `Basic ${Buffer.from(`${user}:${token}`).toString("base64")}`;
}
let pgHost = "localhost";
let pgPort = 5432;
try {
    const db = env.DATABASE_URL || "";
    const u = new URL(db.replace(/^postgresql:/i, "http:"));
    pgHost = u.hostname;
    pgPort = Number(u.port) || 5432;
}
catch {
    add("DATABASE_URL", "INVALID", "could not parse URL");
}
if (!rows.some((r) => r.name === "DATABASE_URL")) {
    const pg = await probeTcp(pgHost, pgPort);
    add(`PostgreSQL ${pgHost}:${pgPort}`, pg.ok ? "OK" : "UNREACHABLE", pg.ok ? "" : pg.err);
}
const jwt = env.JWT_SECRET || "";
add("JWT_SECRET", jwt.length >= 32 ? "OK (length)" : "TOO SHORT", jwt.length >= 32 ? "" : `need ≥32 chars, have ${jwt.length}`);
add("DEVSECOPS_ALLOW_SIMULATION", env.DEVSECOPS_ALLOW_SIMULATION === "true" ? "ON (demo)" : "OFF (production)", "");
add("KUBERNETES_ENABLED", env.KUBERNETES_ENABLED === "true" ? "ON" : "OFF", env.KUBERNETES_ENABLED === "true" ? "" : "cluster metrics / pod counts disabled");
const kubeconfigPath = env.KUBE_CONFIG_PATH?.trim() || path.join(process.env.USERPROFILE || "", ".kube", "config");
if (fs.existsSync(kubeconfigPath)) {
    add("Kubeconfig", "FOUND", kubeconfigPath);
}
else {
    add("Kubeconfig", "MISSING", "set KUBE_CONFIG_PATH or create ~/.kube/config on the machine running the app");
}
const kubectlArgs = ["cluster-info"];
if (env.KUBE_CONFIG_PATH?.trim()) {
    kubectlArgs.unshift("--kubeconfig", env.KUBE_CONFIG_PATH.trim());
}
if (env.KUBE_TLS_SKIP_VERIFY === "true") {
    kubectlArgs.unshift("--insecure-skip-tls-verify");
}
const kubectl = spawnSync("kubectl", kubectlArgs, { encoding: "utf8", timeout: 8000 });
if (kubectl.status === 0) {
    add("kubectl cluster access", "OK", "");
}
else {
    const detail = `${kubectl.stderr || kubectl.stdout}`.trim().split("\n").slice(-1)[0] || "cluster not reachable";
    add("kubectl cluster access", "UNAVAILABLE", detail);
}
if (env.JENKINS_BASE_URL?.trim()) {
    const base = env.JENKINS_BASE_URL.replace(/\/$/, "");
    const headers = {};
    if (env.JENKINS_USERNAME?.trim() && env.JENKINS_API_TOKEN?.trim()) {
        headers.Authorization = basicAuth(env.JENKINS_USERNAME, env.JENKINS_API_TOKEN);
    }
    const r = await probeFetch(`${base}/api/json`, {
        headers,
        accept: (s) => s === 200 || s === 401 || s === 403
    });
    add("Jenkins", r.status === 200
        ? "reachable + auth OK"
        : r.status === 401 || r.status === 403
            ? "reachable but AUTH FAILED"
            : "UNREACHABLE / TLS / DNS", r.err || (r.status ? `HTTP ${r.status}` : ""));
}
else {
    add("Jenkins", "NOT CONFIGURED", "");
}
if (env.HARBOR_BASE_URL?.trim()) {
    const base = env.HARBOR_BASE_URL.replace(/\/$/, "");
    const r = await probeFetch(`${base}/api/v2.0/health`);
    add("Harbor API", r.ok ? `OK (HTTP ${r.status})` : "FAIL", r.err || (r.status ? `HTTP ${r.status}` : ""));
}
else {
    add("Harbor", "NOT CONFIGURED", "");
}
if (env.ARGOCD_BASE_URL?.trim() && env.ARGOCD_AUTH_TOKEN?.trim()) {
    const base = env.ARGOCD_BASE_URL.replace(/\/$/, "");
    const r = await probeFetch(`${base}/api/version`, {
        headers: { Authorization: `Bearer ${env.ARGOCD_AUTH_TOKEN}` },
        accept: (s) => s === 200 || s === 401 || s === 403
    });
    const good = r.status === 200;
    add("Argo CD API + token", good ? "OK (token accepted)" : r.status === 401 || r.status === 403 ? "reachable but AUTH FAILED" : "UNREACHABLE", r.err || "");
}
else if (env.ARGOCD_BASE_URL?.trim()) {
    const base = env.ARGOCD_BASE_URL.replace(/\/$/, "");
    const r = await probeFetch(`${base}/`);
    add("Argo CD (no token test)", r.ok ? `HTTP ${r.status}` : "UNREACHABLE", r.err || "");
}
else {
    add("Argo CD", "NOT CONFIGURED", "");
}
if (env.SONAR_BASE_URL?.trim()) {
    if (isPlaceholder(env.SONAR_TOKEN)) {
        add("SonarQube", "BASE URL set, TOKEN is placeholder", "set SONAR_TOKEN");
    }
    else {
        const base = env.SONAR_BASE_URL.replace(/\/$/, "");
        const r = await probeFetch(`${base}/api/system/status`, {
            headers: { Authorization: `Bearer ${env.SONAR_TOKEN}` },
            accept: (s) => s === 200
        });
        add("SonarQube API + token", r.ok ? "OK" : "FAIL", r.err || (r.status ? `HTTP ${r.status}` : ""));
    }
}
else {
    add("SonarQube", "NOT CONFIGURED", "");
}
if (env.DEPENDENCY_TRACK_BASE_URL?.trim()) {
    if (isPlaceholder(env.DEPENDENCY_TRACK_API_KEY)) {
        add("Dependency-Track", "BASE URL set, API key is placeholder", "");
    }
    else {
        const base = env.DEPENDENCY_TRACK_BASE_URL.replace(/\/$/, "");
        const r = await probeFetch(`${base}/api/version`, {
            headers: { "X-Api-Key": env.DEPENDENCY_TRACK_API_KEY },
            accept: (s) => s === 200
        });
        add("Dependency-Track API", r.ok ? "OK" : "FAIL", r.err || (r.status ? `HTTP ${r.status}` : ""));
    }
}
else {
    add("Dependency-Track", "NOT CONFIGURED", "");
}
if (env.PROMETHEUS_BASE_URL?.trim()) {
    const base = env.PROMETHEUS_BASE_URL.replace(/\/$/, "");
    const r = await probeFetch(`${base}/-/healthy`, { accept: (s) => s === 200 });
    add("Prometheus", r.ok ? "OK" : "UNREACHABLE", r.err || "");
    const hasQueries = env.PROMETHEUS_QUERY_CPU?.trim() && env.PROMETHEUS_QUERY_MEMORY?.trim();
    if (!hasQueries) {
        add("Prometheus dashboard queries", "using built-in defaults", "set PROMETHEUS_QUERY_CPU / PROMETHEUS_QUERY_MEMORY only if your Prometheus labels differ");
    }
}
else {
    add("Prometheus", "NOT CONFIGURED", "");
}
if (env.TRIVY_BASE_URL?.trim()) {
    const base = env.TRIVY_BASE_URL.replace(/\/$/, "");
    const r = await probeFetch(`${base}/healthz`).catch(() => ({ ok: false }));
    const r2 = r.ok
        ? r
        : await probeFetch(`${base}/v1/health`).catch(() => ({ ok: false }));
    const ok = r.ok || r2.ok;
    add("Trivy server", ok ? "reachable" : "UNREACHABLE (try /healthz or /v1/health on your install)", r.err || r2.err || "");
}
else {
    add("Trivy", "NOT CONFIGURED", "");
}
const gitopsUrl = env.GITOPS_REPO_URL?.trim();
const gitopsTok = env.GITOPS_REPO_TOKEN?.trim();
if (gitopsUrl?.includes("github.com")) {
    const m = gitopsUrl.match(/github\.com\/([^/]+)\/([^/.]+)/i);
    if (m && gitopsTok) {
        const api = `https://api.github.com/repos/${m[1]}/${m[2]}`;
        const r = await probeFetch(api, {
            headers: {
                Accept: "application/vnd.github+json",
                Authorization: `Bearer ${gitopsTok}`,
                "User-Agent": "paas-env-check"
            },
            accept: (s) => s === 200 || s === 404 || s === 403
        });
        if (r.status === 200)
            add("GitHub repo (GitOps)", "OK (repo exists, token works)", "");
        else if (r.status === 404)
            add("GitHub repo (GitOps)", "NOT FOUND", "create repo or fix GITOPS_REPO_URL");
        else if (r.status === 403)
            add("GitHub repo (GitOps)", "FORBIDDEN", "token scope / SSO / IP allowlist");
        else
            add("GitHub repo (GitOps)", "FAIL", r.err || `HTTP ${r.status}`);
    }
    else {
        add("GitHub repo (GitOps)", "MISSING TOKEN or bad URL", "");
    }
}
else if (gitopsUrl) {
    add("GitOps repo", "NOT GITHUB", "checker only tests github.com API");
}
else {
    add("GitOps", "NOT CONFIGURED", "");
}
if (env.DOCKERHUB_USERNAME?.trim()) {
    const user = env.DOCKERHUB_USERNAME;
    const r = await probeFetch(`https://hub.docker.com/v2/users/${encodeURIComponent(user)}/`, {
        accept: (s) => s === 200 || s === 404
    });
    add("Docker Hub (public user lookup)", r.status === 200 ? "OK" : r.status === 404 ? "user not found" : "FAIL", r.err || "");
    if (isPlaceholder(env.DOCKERHUB_TOKEN)) {
        add("Docker Hub token", "PLACEHOLDER or weak", "needed for private repos / rate limits");
    }
}
else {
    add("Docker Hub", "USERNAME empty", "");
}
for (const [label, url] of [
    ["Grafana (NEXT_PUBLIC)", env.NEXT_PUBLIC_GRAFANA_URL],
    ["Prometheus UI ref", env.NEXT_PUBLIC_PROMETHEUS_URL]
]) {
    if (!url?.trim()) {
        add(label, "empty", "");
        continue;
    }
    try {
        const u = new URL(url);
        const port = u.port || (u.protocol === "https:" ? 443 : 80);
        const tcp = await probeTcp(u.hostname, Number(port), 3000);
        add(label, tcp.ok ? "host:port open" : "UNREACHABLE", `${u.hostname}:${port}`);
    }
    catch {
        add(label, "bad URL", "");
    }
}
const cosignPath = env.COSIGN_BINARY_PATH || "cosign";
const cos = spawnSync(cosignPath, ["version"], { encoding: "utf8", timeout: 5000 });
add("Cosign CLI", cos.status === 0 ? "found" : "NOT FOUND or not on PATH", cos.status === 0 ? cos.stdout.split("\n")[0]?.slice(0, 60) : "");
if (env.COSIGN_ENFORCE_SIGNED === "true" && cos.status !== 0) {
    add("Cosign enforcement", "ENFORCED but binary missing", "pipelines may fail");
}
if (env.OPA_ENFORCE_SIGNED === "true" && !env.OPA_EVAL_URL?.trim()) {
    add("OPA enforcement", "ENFORCED but OPA_EVAL_URL empty", "");
}
if (env.APPS_PUBLIC_BASE_DOMAIN?.includes("localhost") &&
    env.DEVSECOPS_ALLOW_SIMULATION !== "true") {
    add("APPS_PUBLIC_*", "localhost — not real ingress", "set real domain for production app links");
}
const w = Math.max(...rows.map((r) => r.name.length), 20);
console.log("\n=== Integration check (secrets hidden) ===\n");
for (const { name, status, detail } of rows) {
    const line = `${name.padEnd(w)}  ${status}`;
    console.log(line);
    if (detail)
        console.log(`${"".padEnd(w)}  → ${detail}`);
}
console.log("\nDone.\n");
