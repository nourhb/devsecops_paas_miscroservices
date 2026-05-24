import fs from "fs";
import path from "path";
import ts from "typescript";

const repoPaas = path.resolve(import.meta.dirname, "../..");
const roots = process.argv.slice(2).length
  ? process.argv.slice(2).map((r) => path.resolve(process.cwd(), r))
  : [
      path.join(repoPaas, "frontend/src"),
      path.join(repoPaas, "frontend/scripts"),
      path.join(repoPaas, "scripts"),
      path.join(repoPaas, "jenkins"),
    ];

const printer = ts.createPrinter({ newLine: ts.NewLineKind.LineFeed, removeComments: true });

function walk(dir, exts, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const name of fs.readdirSync(dir)) {
    if (name === "node_modules" || name === ".next") continue;
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) walk(p, exts, out);
    else if (exts.some((e) => name.endsWith(e)) && !name.endsWith(".d.ts")) out.push(p);
  }
  return out;
}

function stripTsLike(file, kind) {
  const source = fs.readFileSync(file, "utf8");
  const sf = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, kind);
  const out = printer.printFile(sf);
  if (out !== source) fs.writeFileSync(file, out, "utf8");
}

function stripShell(file) {
  const lines = fs.readFileSync(file, "utf8").split(/\n/);
  const out = lines
    .map((line, i) => {
      if (i === 0 && line.startsWith("#!")) return line;
      if (/^\s*#/.test(line)) return null;
      const q = line.indexOf(" #");
      if (q >= 0 && !line.slice(0, q).includes('"')) return line.slice(0, q).replace(/\s+$/, "");
      return line;
    })
    .filter((l) => l !== null);
  fs.writeFileSync(file, out.join("\n").replace(/\n{3,}/g, "\n\n"), "utf8");
}

function stripDocker(file) {
  const lines = fs.readFileSync(file, "utf8").split(/\n/);
  fs.writeFileSync(
    file,
    lines.filter((l) => !/^\s*#/.test(l)).join("\n").replace(/\n{3,}/g, "\n\n"),
    "utf8"
  );
}

function stripPy(file) {
  const lines = fs.readFileSync(file, "utf8").split(/\n/);
  const out = [];
  let skipDoc = false;
  for (const line of lines) {
    if (line.trim().startsWith('"""') || line.trim().startsWith("'''")) {
      skipDoc = !skipDoc;
      continue;
    }
    if (skipDoc) continue;
    if (/^\s*#/.test(line)) continue;
    const q = line.indexOf(" #");
    out.push(q >= 0 ? line.slice(0, q).replace(/\s+$/, "") : line);
  }
  fs.writeFileSync(file, out.join("\n").replace(/\n{3,}/g, "\n\n"), "utf8");
}

let n = 0;
for (const root of roots) {
  for (const f of walk(root, [".ts", ".tsx"])) {
    stripTsLike(f, f.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
    n++;
  }
  for (const f of walk(root, [".cjs", ".mjs", ".js"])) {
    if (f.includes("strip-all-comments") || f.includes("node_modules")) continue;
    stripTsLike(f, ts.ScriptKind.JS);
    n++;
  }
  for (const f of walk(root, [".sh"])) {
    stripShell(f);
    n++;
  }
}
for (const f of [
  path.join(repoPaas, "frontend/Dockerfile"),
  path.join(repoPaas, "frontend/Dockerfile.db"),
]) {
  if (fs.existsSync(f)) {
    stripDocker(f);
    n++;
  }
}
const py = path.join(repoPaas, "scripts/create_jenkins_paas_deploy_job.py");
if (fs.existsSync(py)) {
  stripPy(py);
  n++;
}
function stripGroovy(file) {
  let text = fs.readFileSync(file, "utf8");
  text = text.replace(/\/\*[\s\S]*?\*\//g, "");
  const lines = text.split(/\n/).filter((l) => !/^\s*\/\//.test(l));
  fs.writeFileSync(file, lines.join("\n").replace(/\n{3,}/g, "\n\n"), "utf8");
}

const jf = path.join(repoPaas, "jenkins/Jenkinsfile.paas-deploy");
if (fs.existsSync(jf)) {
  stripGroovy(jf);
  n++;
}
console.log(`processed ${n} file passes`);
