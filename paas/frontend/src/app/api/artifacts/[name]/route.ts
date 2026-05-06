import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { NotFoundError } from "@/server/http/errors";
import { fail, ok } from "@/server/http/response";
import { getPlatformArtifactByName } from "@/server/artifacts/artifact-service";
export const runtime = "nodejs";
export async function GET(request: NextRequest, { params }: {
    params: {
        name: string;
    };
}) {
    try {
        await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const artifact = await getPlatformArtifactByName(params.name);
        if (!artifact) {
            throw new NotFoundError("Artifact not found.");
        }
        return ok(artifact);
    }
    catch (error) {
        return fail(error);
    }
}
