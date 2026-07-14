import type { Context, Next } from "hono";
import type { Env, Variables } from "./types";
import { bearerToken, getUserByToken, mintApiToken, sha256Hex } from "./db";

const GITHUB_USER_AGENT = "claudegotchi-server (+https://github.com/claudegotchi)";

interface GitHubUser {
  id: number;
  login: string;
  avatar_url?: string | null;
}

type AppContext = Context<{ Bindings: Env; Variables: Variables }>;

export async function authMiddleware(c: AppContext, next: Next): Promise<Response | void> {
  const token = bearerToken(c.req.header("Authorization"));
  if (!token) return c.json({ error: "unauthorized" }, 401);
  const user = await getUserByToken(c.env.DB, token);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  c.set("user", user);
  await next();
}

export async function handleAuthGithub(c: AppContext): Promise<Response> {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }

  const githubToken = (body as { github_token?: unknown } | null)?.github_token;
  if (typeof githubToken !== "string" || githubToken.length === 0 || githubToken.length > 4096) {
    return c.json({ error: "invalid_github_token" }, 400);
  }

  const ghResponse = await fetch("https://api.github.com/user", {
    headers: {
      Authorization: `Bearer ${githubToken}`,
      "User-Agent": GITHUB_USER_AGENT,
      Accept: "application/vnd.github+json",
    },
  });
  if (!ghResponse.ok) {
    return c.json({ error: "github_unauthorized" }, 401);
  }

  const ghUser = (await ghResponse.json()) as GitHubUser;
  if (typeof ghUser?.id !== "number" || typeof ghUser?.login !== "string") {
    return c.json({ error: "github_unauthorized" }, 401);
  }

  const token = mintApiToken();
  const tokenHash = await sha256Hex(token);
  const now = Date.now();

  await c.env.DB.prepare(
    `INSERT INTO users (id, login, avatar_url, token_hash, token_created_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       login = excluded.login,
       avatar_url = excluded.avatar_url,
       token_hash = excluded.token_hash,
       token_created_at = excluded.token_created_at`
  )
    .bind(ghUser.id, ghUser.login, ghUser.avatar_url ?? null, tokenHash, now, now)
    .run();

  return c.json({
    ok: true,
    token,
    user: { id: ghUser.id, login: ghUser.login, avatar_url: ghUser.avatar_url ?? null },
  });
}
