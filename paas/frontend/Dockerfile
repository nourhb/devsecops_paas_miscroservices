ARG NODE_VERSION=20-alpine
FROM node:${NODE_VERSION} AS deps
WORKDIR /app
RUN apk add --no-cache libc6-compat
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
FROM node:${NODE_VERSION} AS builder
WORKDIR /app
RUN apk add --no-cache libc6-compat openssl
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY jenkins/Jenkinsfile.paas-deploy /tmp/Jenkinsfile.paas-deploy
COPY frontend .
ENV PAAS_JENKINSFILE=/tmp/Jenkinsfile.paas-deploy
RUN node scripts/embed-jenkinsfile.mjs && mkdir -p public && npx prisma generate && npm run build
FROM node:${NODE_VERSION} AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0
RUN addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 --ingroup nodejs nextjs \
    && apk add --no-cache wget openssl \
    && wget -qO /usr/local/bin/cosign https://github.com/sigstore/cosign/releases/download/v2.4.0/cosign-linux-amd64 \
    && chmod +x /usr/local/bin/cosign \
    && chown root:root /usr/local/bin/cosign
COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/node_modules/@kubernetes ./node_modules/@kubernetes
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --chown=nextjs:nodejs jenkins/Jenkinsfile.paas-deploy /app/paas-jenkinsfile-embedded/paas/jenkins/Jenkinsfile.paas-deploy
COPY --chown=nextjs:nodejs jenkins/Jenkinsfile.paas-deploy /app/paas-bundled/paas/jenkins/Jenkinsfile.paas-deploy
COPY gitops/apps/simple-app /app/paas-bundled/paas/gitops/apps/simple-app
USER nextjs
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD wget -q -T 5 -O /dev/null http://127.0.0.1:3000/login
CMD ["node", "server.js"]
