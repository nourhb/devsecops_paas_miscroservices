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

const groovyMain = fs.readFileSync(src, "utf8").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
const stagesPath = path.resolve(path.dirname(src), "Jenkinsfile.paas-deploy-stages.groovy");
const groovyStages = fs.existsSync(stagesPath)
    ? fs.readFileSync(stagesPath, "utf8").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n")
    : "";
const groovyBundle = `${groovyMain}\n${groovyStages}`;
const wrapperRequired = [
    "writeNginxPaasDefaultConf",
    "detectProjectFrameworkFromPackageText",
    "load paasDeployStagesPath",
    "def paasStepOk"
];
const bundleRequired = [
    "PAAS_BUILD_COMPLETE",
    "Step 1 — Params validation",
    "Step 12 — GitOps",
    "env-safe-dotenv-loader-20260601"
];
for (const token of wrapperRequired) {
    if (!groovyMain.includes(token)) {
        console.error(`embed-jenkinsfile: missing ${token} in wrapper ${src}`);
        process.exit(1);
    }
}
for (const token of bundleRequired) {
    if (!groovyBundle.includes(token)) {
        console.error(`embed-jenkinsfile: missing ${token} (main=${src}, stages=${stagesPath})`);
        process.exit(1);
    }
}

const out = path.resolve(__dirname, "../src/server/jenkins/embedded-jenkinsfile.ts");
fs.writeFileSync(
    out,
    `export const EMBEDDED_JENKINSFILE_GROOVY = ${JSON.stringify(groovyMain)} as const;\n`
);

console.log(`embed-jenkinsfile: wrote ${out} (wrapper ${groovyMain.length} bytes + stages ${groovyStages.length} bytes from ${src})`);
