import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, it, vi } from "vitest";
import app from "../src/index";
import type { Env } from "../src/types";

const testEnv = env as unknown as Env;

async function callWorker(url: string, init?: RequestInit): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await app.fetch(new Request(url, init), testEnv, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

function githubUserResponse(id: number, login: string): Response {
  return new Response(JSON.stringify({ id, login, avatar_url: `https://avatars.example/${login}` }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function codeChallenge(verifier: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  let binary = "";
  for (const byte of digest) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

afterEach(() => {
  vi.restoreAllMocks();
});

it("mints a token for a verified GitHub user, upserts the row, and the token authenticates /v1/me", async ({
  expect,
}) => {
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input as Request | string, init);
    expect(request.url).toBe("https://api.github.com/user");
    expect(request.headers.get("User-Agent")).toBeTruthy();
    expect(request.headers.get("Authorization")).toBe("Bearer gh-token-123");
    return githubUserResponse(42, "octocat");
  });

  const response = await callWorker("https://example.com/v1/auth/github", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ github_token: "gh-token-123" }),
  });

  expect(response.status).toBe(200);
  const payload = (await response.json()) as { ok: boolean; token: string; user: { id: number; login: string } };
  expect(payload.ok).toBe(true);
  expect(payload.token.startsWith("cg_")).toBe(true);
  expect(payload.user).toEqual({ id: 42, login: "octocat", avatar_url: "https://avatars.example/octocat" });

  const row = await testEnv.DB.prepare("SELECT login, token_hash FROM users WHERE id = ?").bind(42).first<{
    login: string;
    token_hash: string;
  }>();
  expect(row?.login).toBe("octocat");
  expect(row?.token_hash).toBeTruthy();

  const meResponse = await callWorker("https://example.com/v1/me", {
    headers: { Authorization: `Bearer ${payload.token}` },
  });
  expect(meResponse.status).toBe(200);
  const me = (await meResponse.json()) as { id: number; login: string };
  expect(me.id).toBe(42);
  expect(me.login).toBe("octocat");
});

it("re-login mints a fresh token that invalidates the previous one", async ({ expect }) => {
  vi.spyOn(globalThis, "fetch").mockImplementation(async () => githubUserResponse(7, "mona"));

  const first = await callWorker("https://example.com/v1/auth/github", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ github_token: "first-token" }),
  });
  const firstPayload = (await first.json()) as { token: string };

  const second = await callWorker("https://example.com/v1/auth/github", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ github_token: "second-token" }),
  });
  const secondPayload = (await second.json()) as { token: string };

  expect(secondPayload.token).not.toBe(firstPayload.token);

  const withOldToken = await callWorker("https://example.com/v1/me", {
    headers: { Authorization: `Bearer ${firstPayload.token}` },
  });
  expect(withOldToken.status).toBe(401);

  const withNewToken = await callWorker("https://example.com/v1/me", {
    headers: { Authorization: `Bearer ${secondPayload.token}` },
  });
  expect(withNewToken.status).toBe(200);
});

it("rejects an invalid GitHub token with 401", async ({ expect }) => {
  vi.spyOn(globalThis, "fetch").mockImplementation(async () => new Response("Bad credentials", { status: 401 }));

  const response = await callWorker("https://example.com/v1/auth/github", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ github_token: "bad-token" }),
  });
  expect(response.status).toBe(401);
});

it("rejects unauthenticated and bogus-token requests to /v1/me with 401", async ({ expect }) => {
  const noHeader = await callWorker("https://example.com/v1/me");
  expect(noHeader.status).toBe(401);

  const badToken = await callWorker("https://example.com/v1/me", {
    headers: { Authorization: "Bearer not-a-real-token" },
  });
  expect(badToken.status).toBe(401);
});

it("runs browser OAuth and exchanges a one-time PKCE-bound grant", async ({ expect }) => {
  const verifier = "test-verifier-that-is-long-enough-for-pkce-1234567890";
  const challenge = await codeChallenge(verifier);
  const start = await callWorker("https://example.com/v1/auth/github/web/start", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code_challenge: challenge }),
  });
  expect(start.status).toBe(200);
  const startBody = (await start.json()) as { authorization_url: string };
  const authorization = new URL(startBody.authorization_url);
  expect(authorization.origin + authorization.pathname).toBe("https://github.com/login/oauth/authorize");
  expect(authorization.searchParams.get("client_id")).toBe("test-client-id");
  expect(authorization.searchParams.get("redirect_uri"))
    .toBe("https://example.com/v1/auth/github/web/callback");
  const state = authorization.searchParams.get("state");
  expect(state).toBeTruthy();

  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input as Request | string, init);
    if (request.url === "https://github.com/login/oauth/access_token") {
      expect(await request.text()).toContain("client_secret=test-client-secret");
      return new Response(JSON.stringify({ access_token: "gh-web-token" }), {
        status: 200, headers: { "content-type": "application/json" },
      });
    }
    expect(request.url).toBe("https://api.github.com/user");
    expect(request.headers.get("Authorization")).toBe("Bearer gh-web-token");
    return githubUserResponse(314, "web-user");
  });

  const callback = await callWorker(
    `https://example.com/v1/auth/github/web/callback?code=temporary-code&state=${encodeURIComponent(state!)}`
  );
  expect(callback.status).toBe(302);
  const appCallback = new URL(callback.headers.get("Location")!);
  expect(appCallback.protocol).toBe("claudegotchi:");
  const grant = appCallback.searchParams.get("grant");
  expect(grant?.startsWith("cgg_")).toBe(true);

  const exchange = await callWorker("https://example.com/v1/auth/github/web/exchange", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ grant, code_verifier: verifier }),
  });
  expect(exchange.status).toBe(200);
  const payload = (await exchange.json()) as { token: string; user: { login: string } };
  expect(payload.token.startsWith("cg_")).toBe(true);
  expect(payload.user.login).toBe("web-user");

  const replay = await callWorker("https://example.com/v1/auth/github/web/exchange", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ grant, code_verifier: verifier }),
  });
  expect(replay.status).toBe(401);
});

it("rejects a web OAuth grant with the wrong PKCE verifier", async ({ expect }) => {
  const verifier = "another-verifier-that-is-long-enough-for-pkce-123456";
  const challenge = await codeChallenge(verifier);
  const start = await callWorker("https://example.com/v1/auth/github/web/start", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ code_challenge: challenge }),
  });
  const authorization = new URL(((await start.json()) as { authorization_url: string }).authorization_url);
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    const url = new Request(input as Request | string).url;
    if (url === "https://github.com/login/oauth/access_token") {
      return new Response(JSON.stringify({ access_token: "gh-token" }), {
        headers: { "content-type": "application/json" },
      });
    }
    return githubUserResponse(315, "pkce-user");
  });
  const callback = await callWorker(
    `https://example.com/v1/auth/github/web/callback?code=code&state=${encodeURIComponent(authorization.searchParams.get("state")!)}`
  );
  const grant = new URL(callback.headers.get("Location")!).searchParams.get("grant");
  const exchange = await callWorker("https://example.com/v1/auth/github/web/exchange", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ grant, code_verifier: "wrong-verifier" }),
  });
  expect(exchange.status).toBe(401);
});
