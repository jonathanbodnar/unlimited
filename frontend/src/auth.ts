import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import type { Context } from "hono";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";

export const SESSION_COOKIE = "gw_session";
export const SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000;

const SESSION_SECRET =
  process.env.SESSION_SECRET || randomBytes(32).toString("hex");

if (!process.env.SESSION_SECRET) {
  console.warn(
    "[auth] SESSION_SECRET not set; generated a random one for this process. " +
      "Sessions will reset on redeploy. Set SESSION_SECRET to keep them stable.",
  );
}

function sign(payload: string): string {
  return createHmac("sha256", SESSION_SECRET).update(payload).digest("hex");
}

export function makeSessionToken(): string {
  const exp = Date.now() + SESSION_TTL_MS;
  const payload = `${exp}.ok`;
  return `${payload}.${sign(payload)}`;
}

export function verifySessionToken(token: string | undefined): boolean {
  if (!token) return false;
  const parts = token.split(".");
  if (parts.length !== 3) return false;
  const [exp, marker, sig] = parts;
  const expNum = Number(exp);
  if (!Number.isFinite(expNum) || expNum < Date.now()) return false;
  const expected = sign(`${exp}.${marker}`);
  const a = Buffer.from(sig, "hex");
  const b = Buffer.from(expected, "hex");
  if (a.length !== b.length) return false;
  try {
    return timingSafeEqual(a, b);
  } catch {
    return false;
  }
}

export function isAuthenticated(c: Context): boolean {
  return verifySessionToken(getCookie(c, SESSION_COOKIE));
}

export function setSessionCookie(c: Context): void {
  const proto =
    c.req.header("x-forwarded-proto") ||
    new URL(c.req.url).protocol.replace(":", "");
  const secure = proto === "https";
  setCookie(c, SESSION_COOKIE, makeSessionToken(), {
    httpOnly: true,
    secure,
    sameSite: "Lax",
    path: "/",
    maxAge: Math.floor(SESSION_TTL_MS / 1000),
  });
}

export function clearSessionCookie(c: Context): void {
  deleteCookie(c, SESSION_COOKIE, { path: "/" });
}

export function checkAdminPassword(input: string): boolean {
  const expected = process.env.ADMIN_PASSWORD;
  if (!expected) return false;
  const a = Buffer.from(input);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  try {
    return timingSafeEqual(a, b);
  } catch {
    return false;
  }
}
