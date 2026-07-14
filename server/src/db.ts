import type { UserRow } from "./types";

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export function mintApiToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  const base64url = btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `cg_${base64url}`;
}

export function bearerToken(header: string | undefined | null): string | null {
  if (!header) return null;
  const match = /^Bearer\s+(.+)$/i.exec(header);
  return match ? match[1].trim() : null;
}

export async function getUserByToken(db: D1Database, token: string): Promise<UserRow | null> {
  const hash = await sha256Hex(token);
  const row = await db.prepare("SELECT * FROM users WHERE token_hash = ?").bind(hash).first<UserRow>();
  return row ?? null;
}
