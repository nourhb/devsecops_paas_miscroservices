import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.join(__dirname, "..");
const SKIP_FILES = new Set(["next-env.d.ts", "strip-comments.mjs"]);
function walk(dir, files = []) {
    if (!fs.existsSync(dir)) {
        return files;
    }
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        const name = ent.name;
        if (name === "node_modules" || name === ".next" || name === "dist") {
            continue;
        }
        const p = path.join(dir, name);
        if (ent.isDirectory()) {
            walk(p, files);
        }
        else {
            files.push(p);
        }
    }
    return files;
}
function scriptKind(filePath) {
    if (filePath.endsWith(".tsx")) {
        return ts.ScriptKind.TSX;
    }
    if (filePath.endsWith(".ts")) {
        return ts.ScriptKind.TS;
    }
    if (filePath.endsWith(".mjs") || filePath.endsWith(".cjs") || filePath.endsWith(".js")) {
        return ts.ScriptKind.JS;
    }
    return ts.ScriptKind.Unknown;
}
function stripFile(filePath) {
    const base = path.basename(filePath);
    if (SKIP_FILES.has(base)) {
        return;
    }
    const kind = scriptKind(filePath);
    if (kind === ts.ScriptKind.Unknown) {
        return;
    }
    const content = fs.readFileSync(filePath, "utf8");
    const sf = ts.createSourceFile(filePath, content, ts.ScriptTarget.Latest, true, kind);
    const printer = ts.createPrinter({
        newLine: ts.NewLineKind.LineFeed,
        removeComments: true
    });
    const out = printer.printFile(sf);
    if (out !== content) {
        fs.writeFileSync(filePath, out, "utf8");
        console.log(filePath);
    }
}
const dirs = ["src", "tests", "scripts"].map((d) => path.join(rootDir, d));
for (const d of dirs) {
    for (const f of walk(d)) {
        if (/\.(ts|tsx|mjs|cjs|js)$/.test(f)) {
            stripFile(f);
        }
    }
}
for (const name of [
    "next.config.mjs",
    "playwright.config.ts",
    "vitest.config.ts",
    "postcss.config.js",
    "tailwind.config.ts"
]) {
    const p = path.join(rootDir, name);
    if (fs.existsSync(p)) {
        stripFile(p);
    }
}
