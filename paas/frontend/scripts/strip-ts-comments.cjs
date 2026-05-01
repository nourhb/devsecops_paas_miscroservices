"use strict";
const fs = require("fs");
const path = require("path");
const ts = require("typescript");

const defaultRoots = [path.join(__dirname, "..", "src"), path.join(__dirname, "..", "tests")];
const cliRoots = process.argv.slice(2).map((r) => path.resolve(process.cwd(), r));
const roots = (cliRoots.length ? cliRoots : defaultRoots).filter((d) => fs.existsSync(d));

function walkTs(dir, out = []) {
    for (const name of fs.readdirSync(dir)) {
        if (name === "node_modules" || name === ".next") {
            continue;
        }
        const p = path.join(dir, name);
        const st = fs.statSync(p);
        if (st.isDirectory()) {
            walkTs(p, out);
        }
        else if (/\.tsx?$/.test(name) && !name.endsWith(".d.ts")) {
            out.push(p);
        }
    }
    return out;
}

const printer = ts.createPrinter({
    newLine: ts.NewLineKind.LineFeed,
    removeComments: true
});

let n = 0;
for (const root of roots) {
    for (const file of walkTs(root)) {
        const source = fs.readFileSync(file, "utf8");
        const kind = file.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
        const sf = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, kind);
        const out = printer.printFile(sf);
        if (out !== source) {
            fs.writeFileSync(file, out, "utf8");
            n += 1;
        }
    }
}
console.log(`strip-ts-comments: updated ${n} files`);
