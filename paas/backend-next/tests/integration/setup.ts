import { prisma } from "../../src/lib/prisma";

beforeAll(async () => {
  // Ensure database is reachable before tests
  await prisma.$connect();
});

afterEach(async () => {
  // Best-effort cleanup between tests
  await prisma.scanResult.deleteMany().catch(() => undefined);
  await prisma.deployment.deleteMany().catch(() => undefined);
  await prisma.pipeline.deleteMany().catch(() => undefined);
  await prisma.project.deleteMany().catch(() => undefined);
});

afterAll(async () => {
  await prisma.$disconnect();
});

