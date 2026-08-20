import type { Context } from "hono";
import type { Env, Variables } from "./types";

const VALID_PLATFORMS = new Set(["all", "claude-code", "codex"]);

interface ModelStatRow {
  platform: string;
  model: string;
  tokens_in: number;
  tokens_out: number;
  calls: number;
}

interface ModelUsersRow {
  platform: string;
  model: string;
  users: number;
}

export async function handleStats(c: Context<{ Bindings: Env; Variables: Variables }>): Promise<Response> {
  const platformParam = c.req.query("platform") ?? "all";
  if (!VALID_PLATFORMS.has(platformParam)) return c.json({ error: "invalid_platform" }, 400);

  const platformFilter = platformParam === "all" ? null : platformParam;
  const db = c.env.DB;

  const statsSql = platformFilter
    ? "SELECT platform, model, tokens_in, tokens_out, calls FROM model_stats WHERE platform = ?"
    : "SELECT platform, model, tokens_in, tokens_out, calls FROM model_stats";
  const statsArgs = platformFilter ? [platformFilter] : [];

  const usersSql = platformFilter
    ? `SELECT ups.platform, je.key as model, COUNT(DISTINCT ups.user_id) as users
       FROM user_platform_stats ups, json_each(ups.models_json) je
       WHERE ups.platform = ? GROUP BY ups.platform, je.key`
    : `SELECT ups.platform, je.key as model, COUNT(DISTINCT ups.user_id) as users
       FROM user_platform_stats ups, json_each(ups.models_json) je
       GROUP BY ups.platform, je.key`;
  const usersArgs = platformFilter ? [platformFilter] : [];

  const [statsResult, usersResult] = await Promise.all([
    db.prepare(statsSql).bind(...statsArgs).all<ModelStatRow>(),
    db.prepare(usersSql).bind(...usersArgs).all<ModelUsersRow>(),
  ]);

  const usersByModel = new Map(usersResult.results.map((r) => [`${r.platform}\u0001${r.model}`, r.users]));

  const models = statsResult.results
    .map((row) => ({
      platform: row.platform,
      model: row.model,
      tokens_in: row.tokens_in,
      tokens_out: row.tokens_out,
      calls: row.calls,
      users: usersByModel.get(`${row.platform}\u0001${row.model}`) ?? 0,
    }))
    .sort((a, b) => b.calls - a.calls);

  return c.json({ platform: platformParam, models });
}
