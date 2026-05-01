import { prisma } from "../../src/lib/prisma";
beforeAll(async () => {
    await prisma.$connect();
});
afterEach(async () => {
    await prisma.scanResult.deleteMany().catch(() => undefined);
    await prisma.deployment.deleteMany().catch(() => undefined);
    await prisma.pipeline.deleteMany().catch(() => undefined);
    await prisma.project.deleteMany().catch(() => undefined);
});
afterAll(async () => {
    await prisma.$disconnect();
});
