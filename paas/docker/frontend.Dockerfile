# syntax=docker/dockerfile:1

# Build context: paas/ (see docker-compose.yml). App source: frontend/
ARG NODE_VERSION=20-alpine

# --- dependencies (lockfile-reproducible)
FROM node:${NODE_VERSION} AS deps
WORKDIR /app
RUN apk add --no-cache libc6-compat
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci

# --- build
FROM node:${NODE_VERSION} AS builder
WORKDIR /app
RUN apk add --no-cache libc6-compat openssl
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY frontend .
# Next expects `public/` for static files; keep an empty dir if the repo has none
RUN mkdir -p public
RUN npx prisma generate \
    && npm run build

# --- run (standalone server only)
FROM node:${NODE_VERSION} AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

RUN addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 --ingroup nodejs nextjs \
    && apk add --no-cache wget

COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000

# Liveness only (avoid failing while DB/sync integrations are warming up behind /api/health)
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD wget -q -T 5 -O /dev/null http://127.0.0.1:3000/login || exit 1

CMD ["node", "server.js"]
