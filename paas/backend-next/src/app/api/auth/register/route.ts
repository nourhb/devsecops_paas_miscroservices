import { NextResponse } from "next/server";
import { z } from "zod";
import { v4 as uuidv4 } from "uuid";
import bcrypt from "bcryptjs";
import { db, UserRecord } from "../../../../lib/in-memory-db";

const bodySchema = z.object({
  email: z.string().email(),
  password: z.string().min(8),
  fullName: z.string().optional()
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

  const { email, password, fullName } = parsed.data;
  for (const u of db.users.values()) if (u.email === email) return NextResponse.json({ error: "User exists" }, { status: 409 });

  const id = uuidv4();
  const passwordHash = await bcrypt.hash(password, 10);
  const user: UserRecord = { id, email, fullName, passwordHash, role: "DEVELOPER" };
  db.users.set(id, user);

  return NextResponse.json({ id, email, fullName });
}
