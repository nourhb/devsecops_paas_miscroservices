/** One-off: replace :31073 with :31077 in Project.url (ingress NodePort fix). */
const { PrismaClient } = require("@prisma/client");
const prisma = new PrismaClient();
async function main() {
    const r = await prisma.$executeRawUnsafe(
        `UPDATE "Project" SET url = REPLACE(url, ':31073', ':31077') WHERE url LIKE '%31073%'`
    );
    console.log("Updated rows:", r);
}
main()
    .catch((e) => {
        console.error(e);
        process.exit(1);
    })
    .finally(() => prisma.$disconnect());
