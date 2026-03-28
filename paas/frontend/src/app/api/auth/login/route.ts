import { NextRequest } from "next/server";
import { loginUser } from "@/server/auth/auth-service";
import { fail, ok } from "@/server/http/response";

export const runtime = "nodejs";

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const response = await loginUser(body);
    return ok(response);
  } catch (error) {
    return fail(error);
  }
}
