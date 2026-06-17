#!/usr/bin/env node
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const paasJenkinsfileEnv = (process.env.PAAS_JENKINSFILE || "").trim();
const candidates = [
    path.resolve(__dirname, "../../jenkins/Jenkinsfile.paas-deploy"),
    path.resolve(__dirname, "../../../jenkins/Jenkinsfile.paas-deploy"),
    paasJenkinsfileEnv || null
].filter(Boolean);

let src = "";
for (const c of candidates) {
    if (c && fs.existsSync(c)) {
        src = c;
        break;
    }
}
if (!src) {
    console.error("embed-jenkinsfile: Jenkinsfile.paas-deploy not found");
    process.exit(1);
}

const groovy = fs.readFileSync(src, "utf8").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
const required = [
    "writeNginxPaasDefaultConf",
    "detectProjectFrameworkFromPackageText",
    "def runPaasDeploy",
    "def paasStepOk",
    "PAAS_BUILD_COMPLETE",
    "Step 1 — Params validation",
    "Step 12 — GitOps",
    "env-safe-dotenv-loader-20260601"
];
for (const token of required) {
    if (!groovy.includes(token)) {
        console.error(`embed-jenkinsfile: missing ${token} in ${src}`);
        process.exit(1);
    }
}
if (groovy.includes("load paasDeployStagesPath")) {
    console.error(`embed-jenkinsfile: split Jenkinsfile layout detected in ${src} — merge monolithic first`);
    process.exit(1);
}

const out = path.resolve(__dirname, "../src/server/jenkins/embedded-jenkinsfile.ts");
fs.writeFileSync(
    out,
    `export const EMBEDDED_JENKINSFILE_GROOVY = ${JSON.stringify(groovy)} as const;\n`
);

console.log(`embed-jenkinsfile: wrote ${out} (${groovy.length} bytes from ${src})`);
