import * as jwt from "jsonwebtoken";
import { env } from "../lib/env";

export interface JwtPayload {
  userId: string;
  email: string;
  role: "ADMIN" | "DEVELOPER";
}

export function signToken(payload: JwtPayload): string {
  return jwt.sign(payload, env.JWT_SECRET as jwt.Secret, { expiresIn: env.JWT_EXPIRES_IN as jwt.SignOptions["expiresIn"] });
}

export function verifyToken(token: string): JwtPayload {
  return jwt.verify(token, env.JWT_SECRET as string) as JwtPayload;
}
