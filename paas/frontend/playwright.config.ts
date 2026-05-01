import { platform } from "node:os";
import { defineConfig, devices } from "@playwright/test";
const PLAYWRIGHT_JWT_SECRET = "playwright-test-secret-min-32-chars!!";
const useSystemEdge = platform() === "win32" && !process.env.PLAYWRIGHT_USE_BUNDLED_CHROMIUM;
export default defineConfig({
    testDir: "tests/e2e",
    fullyParallel: true,
    forbidOnly: !!process.env.CI,
    retries: process.env.CI ? 1 : 0,
    workers: 1,
    use: {
        ...devices["Desktop Chrome"],
        ...(useSystemEdge ? { channel: "msedge" as const } : {}),
        baseURL: "http://127.0.0.1:3000",
        trace: "on-first-retry"
    },
    webServer: {
        command: "npm run dev",
        url: "http://127.0.0.1:3000",
        reuseExistingServer: !process.env.CI,
        env: {
            ...process.env,
            JWT_SECRET: PLAYWRIGHT_JWT_SECRET,
            DEVSECOPS_ALLOW_SIMULATION: "true"
        }
    }
});
