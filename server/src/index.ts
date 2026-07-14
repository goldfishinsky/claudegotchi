import { Hono } from "hono";
import type { Context } from "hono";
import type { Env, Variables } from "./types";
import { authMiddleware, handleAuthGithub } from "./auth";
import { handleSync } from "./sync";
import { handleLeaderboard, handleMe, handleDeleteMe } from "./leaderboard";
import { handleStats } from "./stats";

const app = new Hono<{ Bindings: Env; Variables: Variables }>();

app.get("/v1/health", (c) => c.json({ ok: true, time: Date.now() }));

app.post("/v1/auth/github", handleAuthGithub);

app.use("/v1/sync", authMiddleware);
app.post("/v1/sync", handleSync);

app.use("/v1/me", authMiddleware);
app.get("/v1/me", handleMe);
app.delete("/v1/me", handleDeleteMe);

app.get("/v1/leaderboard", (c) => withEdgeCache(c, 60, () => handleLeaderboard(c)));
app.get("/v1/stats/models", (c) => withEdgeCache(c, 300, () => handleStats(c)));

async function withEdgeCache(
  c: Context<{ Bindings: Env; Variables: Variables }, string, object>,
  ttlSeconds: number,
  handler: () => Promise<Response>
): Promise<Response> {
  const cache = caches.default;
  const cacheKey = new Request(c.req.url, { method: "GET" });
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  const response = await handler();
  if (response.status !== 200) return response;

  const cacheable = new Response(response.body, response);
  cacheable.headers.set("Cache-Control", `public, s-maxage=${ttlSeconds}`);
  c.executionCtx.waitUntil(cache.put(cacheKey, cacheable.clone()));
  return cacheable;
}

export default app;
