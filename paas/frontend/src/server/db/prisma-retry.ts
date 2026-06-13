import { prisma } from "@/server/db/prisma";

function isTransientDbError(error: unknown): boolean {
    const msg = error instanceof Error ? error.message : String(error);
    return /can't reach database server|connection refused|ECONNREFUSED|ETIMEDOUT|P1001|P1017|Connection terminated/i.test(msg);
}

export async function withPrismaRetry<T>(operation: () => Promise<T>, attempts = 4): Promise<T> {
    let lastError: unknown;
    for (let i = 0; i < attempts; i++) {
        try {
            return await operation();
        }
        catch (error) {
            lastError = error;
            if (!isTransientDbError(error) || i >= attempts - 1) {
                throw error;
            }
            await new Promise((resolve) => setTimeout(resolve, 500 * (i + 1)));
        }
    }
    throw lastError;
}

export async function prismaDeploymentUpdate(
    deploymentId: string,
    data: Parameters<typeof prisma.deployment.update>[0]["data"]
): Promise<void> {
    await withPrismaRetry(() => prisma.deployment.update({ where: { id: deploymentId }, data }));
}
