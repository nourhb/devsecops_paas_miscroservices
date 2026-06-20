const nextConfig = {
    reactStrictMode: true,
    output: "standalone",
    experimental: {
        outputFileTracingIncludes: {
            "/*": [
                "./node_modules/.prisma/client/**/*",
                "./node_modules/@prisma/client/**/*",
                "./node_modules/@kubernetes/client-node/**/*"
            ]
        },
        serverComponentsExternalPackages: ["@prisma/client", "@kubernetes/client-node"]
    }
};
export default nextConfig;
