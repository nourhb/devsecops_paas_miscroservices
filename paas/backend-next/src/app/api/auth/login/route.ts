import { NextResponse } from "next/server";
import { z } from "zod";
import bcrypt from "bcryptjs";
import { db } from "../../../../lib/in-memory-db";
import { signToken } from "../../../../lib/jwt";

const bodySchema = z.object({
  email: z.string().email(),
  password: z.string().min(1)
});

export async function POST(req: Request) {
  let json: any;
  try {
    json = await req.json();
  } catch (err) {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  const parsed = bodySchema.safeParse(json);
  if (!parsed.success) return NextResponse.json({ error: parsed.error.message }, { status: 400 });

  const { email, password } = parsed.data;
  const user = Array.from(db.users.values()).find((u) => u.email === email);
  if (!user) return NextResponse.json({ error: "Invalid credentials" }, { status: 401 });

  const match = await bcrypt.compare(password, user.passwordHash);
  if (!match) return NextResponse.json({ error: "Invalid credentials" }, { status: 401 });

  const token = signToken({ userId: user.id, email: user.email, role: user.role });
  return NextResponse.json({ token });
}
