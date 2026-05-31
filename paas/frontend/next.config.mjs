const nextConfig = {
    reactStrictMode: true,
    output: "standalone",
    experimental: {
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
