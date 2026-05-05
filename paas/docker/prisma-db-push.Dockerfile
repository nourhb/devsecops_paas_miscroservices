# One-shot Prisma `db push` for the compose stack (context: paas/).
# Installs frontend deps so the CLI matches prisma/schema.prisma (binaryTargets, etc.).
FROM node:20-alpine
WORKDIR /app
RUN apk add --no-cache openssl
COPY frontend/package.json frontend/package-lock.json ./
COPY frontend/prisma ./prisma
RUN npm ci
CMD ["npx", "prisma", "db", "push"]
