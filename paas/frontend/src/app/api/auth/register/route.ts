import { NextRequest } from "next/server";
import { registerUser } from "@/server/auth/auth-service";
import { created, fail } from "@/server/http/response";

export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const response = await registerUser(body);
    return created(response);
  } catch (error) {
    return fail(error);
  }
}
