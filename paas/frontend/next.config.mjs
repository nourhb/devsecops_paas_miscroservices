/** @type {import("next").NextConfig} */
const nextConfig = {
    reactStrictMode: true,
    output: "standalone",
    experimental: {
        /** Prisma query engine binaries are native; ensure they survive file tracing into `.next/standalone`. */
        outputFileTracingIncludes: {
            "/*": [
                "./node_modules/.prisma/client/**/*",
                "./node_modules/@prisma/client/**/*"
            ]
        },
        serverComponentsExternalPackages: ["@prisma/client"]
    }
};
export default nextConfig;
