import fs from "fs";
import path from "path";
import { env } from "@/server/config/env";

export const JENKINSFILE_REL_SEGMENTS = ["paas", "jenkins", "Jenkinsfile.paas-deploy"] as const;
/** Baked into the frontend image at build time — not replaced by the ConfigMap volume mount. */
export const EMBEDDED_JENKINSFILE_ROOT = "/app/paas-jenkinsfile-embedded";
/** May be overridden by ConfigMap mount (can stay stale after image upgrades). */
export const BUNDLED_JENKINSFILE_ROOT = "/app/paas-bundled";
export const MULTI_FRAMEWORK_MARKERS = ["multi-framework-20260611", "multi-framework-20260610"] as const;
export const NGINX_CONF_WRITEFILE_MARKER = "nginx-conf-writefile-20260611";

export function jenkinsfileHasMultiFrameworkMarker(groovy: string): boolean {
    return MULTI_FRAMEWORK_MARKERS.some((m) => groovy.includes(m));
}

export function jenkinsfileHasNginxConfWritefileFix(groovy: string): boolean {
    return groovy.includes(NGINX_CONF_WRITEFILE_MARKER) && groovy.includes("writeNginxPaasDefaultConf");
}

function jenkinsfileAt(root: string): string {
    return path.join(root, ...JENKINSFILE_REL_SEGMENTS);
}

function readIfExists(absPath: string): string | null {
    try {
        if (!fs.existsSync(absPath)) {
            return null;
        }
        return fs.readFileSync(absPath, "utf-8").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
    }
    catch {
        return null;
    }
}

function readEmbeddedModuleGroovy(): string | null {
    try {
        const mod = require("./embedded-jenkinsfile") as { EMBEDDED_JENKINSFILE_GROOVY?: string };
        const groovy = mod.EMBEDDED_JENKINSFILE_GROOVY?.trim();
        if (groovy && jenkinsfileHasMultiFrameworkMarker(groovy) && jenkinsfileHasNginxConfWritefileFix(groovy)) {
            return groovy;
        }
    }
    catch {
        // generated at `npm run build` / Docker builder stage
    }
    return null;
}

export function resolveJenkinsfilePath(): {
    absPath: string;
    root: string;
    source: "bundle-module" | "embedded" | "monorepo" | "bundled";
} | null {
    const fromModule = readEmbeddedModuleGroovy();
    if (fromModule) {
        return {
            absPath: "embedded-jenkinsfile.ts",
            root: "next-bundle",
            source: "bundle-module"
        };
    }
    const override = env.PAAS_MONOREPO_ROOT.trim();
    if (override) {
        const abs = path.resolve(override);
        const candidate = jenkinsfileAt(abs);
        if (fs.existsSync(candidate)) {
            return { absPath: candidate, root: abs, source: "monorepo" };
        }
    }
    let dir = process.cwd();
    for (let i = 0; i < 10; i++) {
        const candidate = jenkinsfileAt(dir);
        if (fs.existsSync(candidate)) {
            return { absPath: candidate, root: dir, source: "monorepo" };
        }
        const parent = path.dirname(dir);
        if (parent === dir) {
            break;
        }
        dir = parent;
    }
    const embedded = jenkinsfileAt(EMBEDDED_JENKINSFILE_ROOT);
    const embeddedText = readIfExists(embedded);
    const bundled = jenkinsfileAt(BUNDLED_JENKINSFILE_ROOT);
    const bundledText = readIfExists(bundled);
    if (embeddedText && jenkinsfileHasMultiFrameworkMarker(embeddedText) && jenkinsfileHasNginxConfWritefileFix(embeddedText)) {
        return { absPath: embedded, root: EMBEDDED_JENKINSFILE_ROOT, source: "embedded" };
    }
    if (embeddedText && jenkinsfileHasNginxConfWritefileFix(embeddedText)
        && (!bundledText || !jenkinsfileHasNginxConfWritefileFix(bundledText))) {
        return { absPath: embedded, root: EMBEDDED_JENKINSFILE_ROOT, source: "embedded" };
    }
    if (bundledText) {
        return { absPath: bundled, root: BUNDLED_JENKINSFILE_ROOT, source: "bundled" };
    }
    return null;
}

export function readResolvedJenkinsfileGroovy(): {
    groovy: string;
    absPath: string;
    source: string;
} | null {
    const fromModule = readEmbeddedModuleGroovy();
    if (fromModule) {
        return {
            groovy: fromModule,
            absPath: "embedded-jenkinsfile.ts",
            source: "next-bundle"
        };
    }
    const resolved = resolveJenkinsfilePath();
    if (!resolved) {
        return null;
    }
    const groovy = readIfExists(resolved.absPath);
    if (!groovy) {
        return null;
    }
    return {
        groovy,
        absPath: resolved.absPath,
        source: `${resolved.source}:${resolved.absPath}`
    };
}
