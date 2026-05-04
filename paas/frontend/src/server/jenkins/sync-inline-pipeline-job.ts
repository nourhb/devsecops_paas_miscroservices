import { exec, execFile } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { promisify } from "util";
import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
import { allowSimulation } from "@/server/integrations/integration-mode";

const execFileAsync = promisify(execFile);
const execAsync = promisify(exec);

function scriptRelativePathExists(root: string): boolean {
    return fs.existsSync(path.join(root, "paas", "scripts", "jenkins_create_paas_deploy_job.py"));
}

function findMonorepoRoot(): string | null {
    const override = env.PAAS_MONOREPO_ROOT.trim();
    if (override) {
        const abs = path.resolve(override);
        if (scriptRelativePathExists(abs)) {
            return abs;
        }
    }
    let dir = process.cwd();
    for (let i = 0; i < 10; i++) {
        if (scriptRelativePathExists(dir)) {
            return dir;
        }
        const parent = path.dirname(dir);
        if (parent === dir) {
            break;
        }
        dir = parent;
    }
    return null;
}

function pickEnvFileOnDisk(root: string): string | null {
    const a = path.join(root, "paas", "frontend", ".env");
    const b = path.join(root, "paas", ".env");
    if (fs.existsSync(a)) {
        return a;
    }
    if (fs.existsSync(b)) {
        return b;
    }
    return null;
}

function writeTempEnvFromProcess(): string {
    const base = env.JENKINS_BASE_URL.trim();
    const user = env.JENKINS_USERNAME.trim();
    const token = env.JENKINS_API_TOKEN.trim();
    if (!base || !user || !token) {
        throw new IntegrationError(
            "Cannot sync Jenkins job: no paas/frontend/.env on disk and JENKINS_BASE_URL / JENKINS_USERNAME / JENKINS_API_TOKEN are incomplete."
        );
    }
    const fd = path.join(os.tmpdir(), `paas-jenkins-sync-${process.pid}-${Date.now()}.env`);
    const lines = [`JENKINS_BASE_URL=${base}`, `JENKINS_USERNAME=${user}`, `JENKINS_API_TOKEN=${token}`];
    fs.writeFileSync(fd, `${lines.join("\n")}\n`, "utf8");
    return fd;
}

function stripEnvQuotes(s: string): string {
    const t = s.trim();
    if (t.length >= 2 && ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'")))) {
        return t.slice(1, -1).trim();
    }
    return t;
}

/** True when value should be resolved via PATH (e.g. `python`), not as a filesystem path. */
function isBareCommandName(p: string): boolean {
    if (path.isAbsolute(p)) {
        return false;
    }
    return !p.includes("/") && !p.includes("\\");
}

/**
 * Turn PYTHON_CMD into a real interpreter path. Rejects Start Menu "Python 3.x" folders that only hold shortcuts.
 */
function resolveConfiguredPythonExecutable(configured: string): { executable: string; prefixArgs: string[] } {
    const raw = stripEnvQuotes(configured);
    if (!raw) {
        throw new IntegrationError("PYTHON_CMD is set but empty.");
    }
    if (isBareCommandName(raw)) {
        return { executable: raw, prefixArgs: [] };
    }
    const p = path.resolve(raw);
    if (!fs.existsSync(p)) {
        throw new IntegrationError(
            `PYTHON_CMD points to "${configured}" but that path does not exist. Use the full path to python.exe (for example under %LocalAppData%\\Programs\\Python\\Python311\\), or unset PYTHON_CMD to use python / py from PATH.`
        );
    }
    const st = fs.statSync(p);
    if (st.isFile()) {
        return { executable: p, prefixArgs: [] };
    }
    if (st.isDirectory()) {
        const exe = path.join(p, "python.exe");
        if (fs.existsSync(exe) && fs.statSync(exe).isFile()) {
            return { executable: exe, prefixArgs: [] };
        }
        throw new IntegrationError(
            `PYTHON_CMD points to a folder that is not a Python install: ${p}. ` +
                `Use the full path to python.exe (not the Start Menu "Python 3.x" folder). ` +
                `Typical install: %LocalAppData%\\Programs\\Python\\Python311\\python.exe. ` +
                `Or remove PYTHON_CMD so the app tries python, python3, then py -3.`
        );
    }
    throw new IntegrationError(`PYTHON_CMD path is not a file or directory: ${p}`);
}

async function pickPython(): Promise<{ executable: string; prefixArgs: string[] }> {
    const configured = env.PYTHON_CMD.trim();
    if (configured) {
        const chosen = resolveConfiguredPythonExecutable(configured);
        try {
            await execFileAsync(chosen.executable, [...chosen.prefixArgs, "--version"], {
                timeout: 8000,
                windowsHide: true,
                encoding: "utf8"
            });
        } catch {
            throw new IntegrationError(
                `PYTHON_CMD "${configured}" does not run (python --version failed). Fix the path or remove PYTHON_CMD.`
            );
        }
        return chosen;
    }
    /** On Windows, `py -3` under execFile sometimes yields vague "Command failed"; try `python` / `python3` first. */
    const candidates: { executable: string; prefixArgs: string[] }[] =
        process.platform === "win32"
            ? [
                  { executable: "python", prefixArgs: [] },
                  { executable: "python3", prefixArgs: [] },
                  { executable: "py", prefixArgs: ["-3"] }
              ]
            : [
                  { executable: "python3", prefixArgs: [] },
                  { executable: "python", prefixArgs: [] }
              ];
    for (const c of candidates) {
        try {
            await execFileAsync(c.executable, [...c.prefixArgs, "--version"], {
                timeout: 8000,
                windowsHide: true,
                encoding: "utf8"
            });
            return c;
        } catch {
            continue;
        }
    }
    throw new IntegrationError(
        "Python 3 is required to sync the Jenkins inline job. Install python3, add it to PATH, or set PYTHON_CMD in the environment."
    );
}

function formatExecError(err: unknown, cmdLine: string): string {
    const parts: string[] = [];
    if (err instanceof Error && err.message) {
        parts.push(err.message);
    }
    if (err && typeof err === "object") {
        const o = err as { stderr?: string | Buffer; stdout?: string | Buffer; code?: number | string };
        const toStr = (x: string | Buffer | undefined): string => {
            if (x === undefined) {
                return "";
            }
            return typeof x === "string" ? x : x.toString("utf8");
        };
        const errOut = toStr(o.stderr).trim();
        if (errOut) {
            parts.push(errOut);
        }
        const stdOut = toStr(o.stdout).trim();
        if (stdOut && !errOut) {
            parts.push(stdOut);
        }
        if (o.code !== undefined && o.code !== null) {
            parts.push(`(exit ${o.code})`);
        }
    }
    if (!parts.length) {
        parts.push(String(err));
    }
    return [parts.join("\n"), `Full command: ${cmdLine}`].join("\n");
}

/** Quote for cmd.exe when path has spaces or special chars (e.g. `C:\Users\hp elite\...`). */
function winCmdArg(s: string): string {
    if (/^[a-zA-Z0-9._\-:=]+$/.test(s)) {
        return s;
    }
    return `"${s.replace(/"/g, '\\"')}"`;
}

function buildSyncDisplayCmdLine(
    executable: string,
    prefixArgs: string[],
    scriptPath: string,
    jobName: string,
    envFile: string
): string {
    const args = [...prefixArgs, scriptPath, "--job-name", jobName, "--env-file", envFile];
    if (process.platform === "win32") {
        return [winCmdArg(executable), ...prefixArgs.map(winCmdArg), winCmdArg(scriptPath), "--job-name", winCmdArg(jobName), "--env-file", winCmdArg(envFile)].join(" ");
    }
    return [executable, ...args.map((a) => (/\s/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a))].join(" ");
}

async function runPythonScript(
    root: string,
    executable: string,
    prefixArgs: string[],
    scriptPath: string,
    jobName: string,
    envFile: string
): Promise<{ stdout: string; stderr: string; cmdLine: string }> {
    const args = [...prefixArgs, scriptPath, "--job-name", jobName, "--env-file", envFile];
    const cmdLine = buildSyncDisplayCmdLine(executable, prefixArgs, scriptPath, jobName, envFile);
    if (process.platform === "win32") {
        const { stdout, stderr } = await execAsync(cmdLine, {
            cwd: root,
            timeout: 120_000,
            maxBuffer: 4 * 1024 * 1024,
            windowsHide: true,
            encoding: "utf8"
        });
        return { stdout: stdout ?? "", stderr: stderr ?? "", cmdLine };
    }
    const { stdout, stderr } = await execFileAsync(executable, args, {
        cwd: root,
        timeout: 120_000,
        maxBuffer: 4 * 1024 * 1024,
        windowsHide: true,
        encoding: "utf8"
    });
    return { stdout: stdout ?? "", stderr: stderr ?? "", cmdLine };
}

/**
 * Pushes `Jenkinsfile.paas-deploy` into Jenkins (same as `python paas/scripts/jenkins_create_paas_deploy_job.py`).
 * Skipped when simulation mode, Jenkins folder layouts, or unsupported multi-segment job names.
 */
export async function syncInlinePaasDeployJenkinsJobBeforeTrigger(jobName: string): Promise<string> {
    if (env.JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER !== "true") {
        return "[jenkins-sync] Skipped: JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false.";
    }
    if (allowSimulation()) {
        return "[jenkins-sync] Skipped: DEVSECOPS_ALLOW_SIMULATION=true.";
    }
    if (!env.JENKINS_BASE_URL.trim() || !env.JENKINS_USERNAME.trim() || !env.JENKINS_API_TOKEN.trim()) {
        return "[jenkins-sync] Skipped: Jenkins not configured.";
    }
    if (env.JENKINS_JOB_FOLDER.trim()) {
        return "[jenkins-sync] Skipped: JENKINS_JOB_FOLDER is set (script targets /job/<name> only). Run jenkins_create_paas_deploy_job.py manually if needed.";
    }
    const trimmedJob = jobName.trim();
    if (!trimmedJob || trimmedJob.includes("/")) {
        return "[jenkins-sync] Skipped: folder-qualified job name (use manual sync for nested jobs).";
    }

    const root = findMonorepoRoot();
    if (!root) {
        throw new IntegrationError(
            "Cannot find monorepo root (expected paas/scripts/jenkins_create_paas_deploy_job.py). Set PAAS_MONOREPO_ROOT or run the app from inside the repository."
        );
    }
    const scriptPath = path.join(root, "paas", "scripts", "jenkins_create_paas_deploy_job.py");
    if (!fs.existsSync(scriptPath)) {
        throw new IntegrationError(`Missing Jenkins sync script: ${scriptPath}`);
    }

    let envFile = pickEnvFileOnDisk(root);
    let cleanup: (() => void) | null = null;
    if (!envFile) {
        envFile = writeTempEnvFromProcess();
        cleanup = () => {
            try {
                fs.unlinkSync(envFile!);
            } catch {
                /* ignore */
            }
        };
    }

    const { executable, prefixArgs } = await pickPython();

    try {
        const { stdout, stderr, cmdLine } = await runPythonScript(root, executable, prefixArgs, scriptPath, trimmedJob, envFile);
        const out = [stdout?.trim(), stderr?.trim()].filter(Boolean).join("\n");
        return `[jenkins-sync] OK (${trimmedJob})\n${out}`.trim();
    } catch (err: unknown) {
        const cmdLine = buildSyncDisplayCmdLine(executable, prefixArgs, scriptPath, trimmedJob, envFile);
        const detail = formatExecError(err, cmdLine);
        throw new IntegrationError(`Jenkins job sync failed:\n${detail}`);
    } finally {
        cleanup?.();
    }
}
