import type { Context } from "hono";
import type { Env, Variables } from "./types";

const VALID_PLATFORMS = new Set(["all", "claude-code"]);

interface ModelStatRow {
  model: string;
  tokens_in: number;
  tokens_out: number;
  calls: number;
}

interface ModelUsersRow {
  model: string;
  users: number;
}

export async function handleStats(c: Context<{ Bindings: Env; Variables: Variables }>): Promise<Response> {
  const platformParam = c.req.query("platform") ?? "all";
  if (!VALID_PLATFORMS.has(platformParam)) return c.json({ error: "invalid_platform" }, 400);

  const platformFilter = platformParam === "all" ? null : platformParam;
  const db = c.env.DB;

  const statsSql = platformFilter
    ? "SELECT model, tokens_in, tokens_out, calls FROM model_stats WHERE platform = ?"
    : "SELECT model, SUM(tokens_in) as tokens_in, SUM(tokens_out) as tokens_out, SUM(calls) as calls FROM model_stats GROUP BY model";
  const statsArgs = platformFilter ? [platformFilter] : [];

  const usersSql = platformFilter
    ? "SELECT je.key as model, COUNT(DISTINCT u.id) as users FROM users u, json_each(u.models_json) je WHERE u.platform = ? GROUP BY je.key"
    : "SELECT je.key as model, COUNT(DISTINCT u.id) as users FROM users u, json_each(u.models_json) je GROUP BY je.key";
  const usersArgs = platformFilter ? [platformFilter] : [];

  const [statsResult, usersResult] = await Promise.all([
    db.prepare(statsSql).bind(...statsArgs).all<ModelStatRow>(),
    db.prepare(usersSql).bind(...usersArgs).all<ModelUsersRow>(),
  ]);

  const usersByModel = new Map(usersResult.results.map((r) => [r.model, r.users]));

  const models = statsResult.results
    .map((row) => ({
      model: row.model,
      tokens_in: row.tokens_in,
      tokens_out: row.tokens_out,
      calls: row.calls,
      users: usersByModel.get(row.model) ?? 0,
    }))
    .sort((a, b) => b.calls - a.calls);

  return c.json({ platform: platformParam, models });
}
