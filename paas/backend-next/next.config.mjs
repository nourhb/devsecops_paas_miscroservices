/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  output: "standalone", // required for production Docker image
  experimental: {
    typedRoutes: false
  }
};

export default nextConfig;
