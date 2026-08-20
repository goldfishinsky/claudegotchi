import type { Context, Next } from "hono";
import type { Env, Variables } from "./types";
import { bearerToken, getUserByToken, mintApiToken, sha256Hex } from "./db";

const GITHUB_USER_AGENT = "claudegotchi-server (+https://github.com/claudegotchi)";

interface GitHubUser {
  id: number;
  login: string;
  avatar_url?: string | null;
}

interface OAuthState {
  issued_at: number;
  code_challenge: string;
}

interface OAuthGrantRow {
  code_challenge: string;
  github_id: number;
  github_login: string;
  avatar_url: string | null;
  expires_at: number;
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

  const ghUser = await githubUser(githubToken);
  if (!ghUser) return c.json({ error: "github_unauthorized" }, 401);
  return c.json(await mintUserSession(c.env, ghUser));
}

export async function handleGithubWebStart(c: AppContext): Promise<Response> {
  if (!oauthConfigured(c.env)) return c.json({ error: "oauth_not_configured" }, 503);
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }
  const challenge = (body as { code_challenge?: unknown } | null)?.code_challenge;
  if (typeof challenge !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(challenge)) {
    return c.json({ error: "invalid_code_challenge" }, 400);
  }

  const callback = new URL("/v1/auth/github/web/callback", c.req.url).toString();
  const state = await encodeState(c.env.OAUTH_STATE_SECRET, {
    issued_at: Date.now(), code_challenge: challenge,
  });
  const authorization = new URL("https://github.com/login/oauth/authorize");
  authorization.searchParams.set("client_id", c.env.GITHUB_CLIENT_ID);
  authorization.searchParams.set("redirect_uri", callback);
  authorization.searchParams.set("state", state);
  authorization.searchParams.set("prompt", "select_account");
  return c.json({ authorization_url: authorization.toString() });
}

export async function handleGithubWebCallback(c: AppContext): Promise<Response> {
  if (!oauthConfigured(c.env)) return c.text("GitHub OAuth is not configured", 503);
  const state = await decodeState(c.env.OAUTH_STATE_SECRET, c.req.query("state") ?? "");
  if (!state || Date.now() - state.issued_at > 10 * 60 * 1000) {
    return c.text("Invalid or expired OAuth state", 400);
  }
  if (c.req.query("error")) return c.redirect(callbackURL({ error: "oauth_denied" }));
  const code = c.req.query("code");
  if (!code) return c.text("Missing OAuth code", 400);

  const redirectUri = new URL("/v1/auth/github/web/callback", c.req.url).toString();
  const tokenResponse = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" },
    body: formEncode({
      client_id: c.env.GITHUB_CLIENT_ID,
      client_secret: c.env.GITHUB_CLIENT_SECRET,
      code,
      redirect_uri: redirectUri,
    }),
  });
  if (!tokenResponse.ok) return c.redirect(callbackURL({ error: "oauth_exchange_failed" }));
  const tokenBody = (await tokenResponse.json()) as { access_token?: unknown };
  if (typeof tokenBody.access_token !== "string") {
    return c.redirect(callbackURL({ error: "oauth_exchange_failed" }));
  }
  const user = await githubUser(tokenBody.access_token);
  if (!user) return c.redirect(callbackURL({ error: "github_unauthorized" }));

  const grant = randomToken("cgg_");
  const grantHash = await sha256Hex(grant);
  const now = Date.now();
  await c.env.DB.prepare("DELETE FROM oauth_grants WHERE expires_at <= ?").bind(now).run();
  await c.env.DB.prepare(
    `INSERT INTO oauth_grants
       (grant_hash, code_challenge, github_id, github_login, avatar_url, expires_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    grantHash, state.code_challenge, user.id, user.login, user.avatar_url ?? null,
    now + 5 * 60 * 1000, now
  ).run();
  return c.redirect(callbackURL({ grant }));
}

export async function handleGithubWebExchange(c: AppContext): Promise<Response> {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }
  const grant = (body as { grant?: unknown } | null)?.grant;
  const verifier = (body as { code_verifier?: unknown } | null)?.code_verifier;
  if (typeof grant !== "string" || typeof verifier !== "string") {
    return c.json({ error: "invalid_grant" }, 400);
  }
  const grantHash = await sha256Hex(grant);
  const row = await c.env.DB.prepare(
    `SELECT code_challenge, github_id, github_login, avatar_url, expires_at
     FROM oauth_grants WHERE grant_hash = ?`
  ).bind(grantHash).first<OAuthGrantRow>();
  if (!row || row.expires_at <= Date.now()
      || await pkceChallenge(verifier) !== row.code_challenge) {
    return c.json({ error: "invalid_grant" }, 401);
  }
  await c.env.DB.prepare("DELETE FROM oauth_grants WHERE grant_hash = ?").bind(grantHash).run();
  return c.json(await mintUserSession(c.env, {
    id: row.github_id, login: row.github_login, avatar_url: row.avatar_url,
  }));
}

async function githubUser(githubToken: string): Promise<GitHubUser | null> {
  const ghResponse = await fetch("https://api.github.com/user", {
    headers: {
      Authorization: `Bearer ${githubToken}`,
      "User-Agent": GITHUB_USER_AGENT,
      Accept: "application/vnd.github+json",
    },
  });
  if (!ghResponse.ok) return null;

  const ghUser = (await ghResponse.json()) as GitHubUser;
  if (typeof ghUser?.id !== "number" || typeof ghUser?.login !== "string") {
    return null;
  }
  return ghUser;
}

async function mintUserSession(env: Env, ghUser: GitHubUser) {
  const token = mintApiToken();
  const tokenHash = await sha256Hex(token);
  const now = Date.now();

  await env.DB.prepare(
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

  return {
    ok: true,
    token,
    user: { id: ghUser.id, login: ghUser.login, avatar_url: ghUser.avatar_url ?? null },
  };
}

function oauthConfigured(env: Env): boolean {
  return Boolean(env.GITHUB_CLIENT_ID && env.GITHUB_CLIENT_SECRET && env.OAUTH_STATE_SECRET
    && !env.GITHUB_CLIENT_ID.startsWith("REPLACE_")
    && !env.GITHUB_CLIENT_SECRET.startsWith("REPLACE_"));
}

function callbackURL(query: Record<string, string>): string {
  const url = new URL("claudegotchi://oauth/github");
  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
  return url.toString();
}

function formEncode(values: Record<string, string>): string {
  return new URLSearchParams(values).toString();
}

function randomToken(prefix: string): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return prefix + base64URL(bytes);
}

async function pkceChallenge(verifier: string): Promise<string> {
  return base64URL(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
}

async function encodeState(secret: string, state: OAuthState): Promise<string> {
  const payload = base64URL(new TextEncoder().encode(JSON.stringify(state)));
  const signature = await hmac(secret, payload);
  return `${payload}.${base64URL(signature)}`;
}

async function decodeState(secret: string, encoded: string): Promise<OAuthState | null> {
  const [payload, signature, extra] = encoded.split(".");
  if (!payload || !signature || extra) return null;
  const expected = await hmac(secret, payload);
  const actual = fromBase64URL(signature);
  if (actual.length !== expected.length) return null;
  let mismatch = 0;
  for (let i = 0; i < actual.length; i += 1) mismatch |= actual[i] ^ expected[i];
  if (mismatch !== 0) return null;
  try {
    const parsed = JSON.parse(new TextDecoder().decode(fromBase64URL(payload))) as OAuthState;
    if (typeof parsed.issued_at !== "number" || typeof parsed.code_challenge !== "string") return null;
    return parsed;
  } catch {
    return null;
  }
}

async function hmac(secret: string, value: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value)));
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function fromBase64URL(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}
