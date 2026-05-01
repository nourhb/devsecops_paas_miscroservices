import path from "node:path";
import { defineConfig } from "vitest/config";
export default defineConfig({
    test: {
        environment: "node",
        globals: false,
        setupFiles: ["./tests/api/setup.ts"],
        include: ["tests/api/**/*.test.ts"],
        testTimeout: 15000
    },
    resolve: {
        alias: {
            "@": path.resolve(__dirname, "./src")
        }
    }
});
