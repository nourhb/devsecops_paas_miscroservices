import { beforeEach, describe, expect, it, vi } from "vitest";
const integrationFetchMock = vi.hoisted(() => vi.fn());
vi.mock("@/server/http/integration-fetch", () => ({
    integrationFetch: integrationFetchMock
}));
import { detectRepositoryLanguage } from "@/server/projects/repository-language";
function jsonResponse(data: unknown, status: number = 200) {
    return new Response(JSON.stringify(data), {
        status,
        headers: {
            "Content-Type": "application/json"
        }
    });
}
describe("detectRepositoryLanguage", () => {
    beforeEach(() => {
        integrationFetchMock.mockReset();
    });
    it("detects Next.js from package.json", async () => {
        integrationFetchMock
            .mockResolvedValueOnce(jsonResponse({
            default_branch: "main",
            language: "TypeScript"
        }))
            .mockResolvedValueOnce(jsonResponse([
            { name: "package.json", type: "file" }
        ]))
            .mockResolvedValueOnce(jsonResponse({
            encoding: "base64",
            content: Buffer.from(JSON.stringify({
                dependencies: {
                    next: "^14.0.0",
                    react: "^18.0.0"
                }
            }), "utf8").toString("base64")
        }));
        const detected = await detectRepositoryLanguage({
            gitRepositoryUrl: "https://github.com/nourhb/Food-Delivery-DevSecOps.git",
            branch: "main"
        });
        expect(detected.language).toBe("Next.js");
        expect(detected.buildProfile).toBe("node");
        expect(detected.hasDockerfile).toBe(false);
        expect(detected.suggestedDockerfile).toContain("FROM node");
    });
    it("detects Spring Boot from pom.xml", async () => {
        integrationFetchMock
            .mockResolvedValueOnce(jsonResponse({
            default_branch: "main",
            language: "Java"
        }))
            .mockResolvedValueOnce(jsonResponse([
            { name: "pom.xml", type: "file" }
        ]))
            .mockResolvedValueOnce(jsonResponse({
            encoding: "base64",
            content: Buffer.from("<project><artifactId>spring-boot-starter-web</artifactId></project>", "utf8").toString("base64")
        }));
        const detected = await detectRepositoryLanguage({
            gitRepositoryUrl: "https://github.com/example/demo.git",
            branch: "main"
        });
        expect(detected.language).toBe("Spring Boot");
        expect(detected.buildProfile).toBe("java");
        expect(detected.hasDockerfile).toBe(false);
        expect(detected.suggestedDockerfile).toContain("eclipse-temurin");
    });
    it("detects Dockerfile at root and omits suggested content", async () => {
        integrationFetchMock
            .mockResolvedValueOnce(jsonResponse({
            default_branch: "main",
            language: "TypeScript"
        }))
            .mockResolvedValueOnce(jsonResponse([
            { name: "package.json", type: "file" },
            { name: "Dockerfile", type: "file" }
        ]))
            .mockResolvedValueOnce(jsonResponse({
            encoding: "base64",
            content: Buffer.from(JSON.stringify({
                dependencies: { next: "^14.0.0", react: "^18.0.0" }
            }), "utf8").toString("base64")
        }));
        const detected = await detectRepositoryLanguage({
            gitRepositoryUrl: "https://github.com/example/app.git",
            branch: "main"
        });
        expect(detected.hasDockerfile).toBe(true);
        expect(detected.suggestedDockerfile).toBeUndefined();
    });
});
