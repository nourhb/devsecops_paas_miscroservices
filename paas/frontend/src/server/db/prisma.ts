import { PrismaClient } from "@prisma/client";
declare global {
    var prismaGlobal: PrismaClient | undefined;
}
function prismaDatabaseUrl(): string {
    const raw = process.env.DATABASE_URL ?? "";
    if (!raw) {
        return raw;
    }
    try {
        const u = new URL(raw);
        if (!u.searchParams.has("connection_limit")) {
            u.searchParams.set("connection_limit", process.env.PRISMA_CONNECTION_LIMIT ?? "25");
        }
        if (!u.searchParams.has("pool_timeout")) {
            u.searchParams.set("pool_timeout", process.env.PRISMA_POOL_TIMEOUT ?? "30");
        }
        return u.toString();
    }
    catch {
        return raw;
    }
}
export const prisma = global.prismaGlobal ||
    new PrismaClient({
        log: process.env.NODE_ENV === "development" ? ["error", "warn"] : ["error"],
        datasources: {
            db: {
                url: prismaDatabaseUrl()
            }
        }
    });
if (process.env.NODE_ENV !== "production") {
    global.prismaGlobal = prisma;
}
