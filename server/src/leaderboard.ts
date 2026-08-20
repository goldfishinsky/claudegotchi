import type { Context } from "hono";
import type { Env, Variables } from "./types";

const PAGE_SIZE = 50;
const MAX_PAGE = 10;
const STALE_MS = 7 * 24 * 60 * 60 * 1000;
const VALID_PLATFORMS = new Set(["all", "claude-code", "codex"]);
const VALID_BOARDS = new Set(["tokens", "survival_current", "survival_best"]);

type AppContext = Context<{ Bindings: Env; Variables: Variables }>;

interface LeaderboardRow {
  id: number;
  login: string;
  avatar_url: string | null;
  pet_species: string | null;
  pet_name: string | null;
  value: number;
}

export async function handleLeaderboard(c: AppContext): Promise<Response> {
  const board = c.req.query("board") ?? "";
  const platformParam = c.req.query("platform") ?? "all";
  const page = Number(c.req.query("page") ?? "1");

  if (!VALID_BOARDS.has(board)) return c.json({ error: "invalid_board" }, 400);
  if (!VALID_PLATFORMS.has(platformParam)) return c.json({ error: "invalid_platform" }, 400);
  if (!Number.isInteger(page) || page < 1 || page > MAX_PAGE) return c.json({ error: "invalid_page" }, 400);

  const platformFilter = platformParam === "all" ? null : platformParam;
  const offset = (page - 1) * PAGE_SIZE;
  const now = Date.now();

  const baseWhere = ["u.hidden = 0"];
  const baseArgs: unknown[] = [];
  let fromSql = "users u";

  let valueExpr: string;
  let orderExpr: string;
  let petSpeciesExpr = "u.pet_species";
  let petNameExpr = "u.pet_name";
  const selectArgs: unknown[] = [];

  if (board === "tokens") {
    if (platformFilter) {
      fromSql = "users u JOIN user_platform_stats ups ON ups.user_id = u.id AND ups.platform = ?";
      baseArgs.push(platformFilter);
      valueExpr = "(ups.tokens_in + ups.tokens_out)";
      orderExpr = "(ups.tokens_in + ups.tokens_out) DESC";
    } else {
      valueExpr = "(u.tokens_in + u.tokens_out)";
      orderExpr = "(u.tokens_in + u.tokens_out) DESC";
    }
  } else if (board === "survival_best") {
    valueExpr = "u.best_survival_ms";
    orderExpr = "u.best_survival_ms DESC";
    petSpeciesExpr = "u.best_pet_species";
    petNameExpr = "u.best_pet_name";
  } else {
    valueExpr = "(? - u.pet_birthday)";
    selectArgs.push(now);
    orderExpr = "u.pet_birthday ASC";
    baseWhere.push("u.pet_birthday IS NOT NULL", "u.last_sync_at IS NOT NULL", "u.last_sync_at >= ?");
    baseArgs.push(now - STALE_MS);
  }
  if (platformFilter && board !== "tokens") {
    baseWhere.push(
      "EXISTS (SELECT 1 FROM user_platform_stats ups WHERE ups.user_id = u.id AND ups.platform = ?)"
    );
    baseArgs.push(platformFilter);
  }

  const whereSql = baseWhere.join(" AND ");

  const countRow = await c.env.DB.prepare(`SELECT COUNT(*) as total FROM ${fromSql} WHERE ${whereSql}`)
    .bind(...baseArgs)
    .first<{ total: number }>();
  const total = countRow?.total ?? 0;
  const totalPages = Math.min(MAX_PAGE, Math.max(1, Math.ceil(total / PAGE_SIZE)));

  const rowsResult = await c.env.DB.prepare(
    `SELECT u.id, u.login, u.avatar_url, ${petSpeciesExpr} as pet_species, ${petNameExpr} as pet_name, ${valueExpr} as value
     FROM ${fromSql}
     WHERE ${whereSql}
     ORDER BY ${orderExpr}
     LIMIT ? OFFSET ?`
  )
    .bind(...selectArgs, ...baseArgs, PAGE_SIZE, offset)
    .all<LeaderboardRow>();

  const valueKey = board === "tokens" ? "value" : "value_ms";
  const rows = rowsResult.results.map((row, index) => ({
    rank: offset + index + 1,
    id: row.id,
    login: row.login,
    avatar_url: row.avatar_url,
    pet: row.pet_species !== null ? { species: row.pet_species, name: row.pet_name } : null,
    [valueKey]: row.value,
  }));

  return c.json({
    board,
    platform: platformParam,
    page,
    page_size: PAGE_SIZE,
    total,
    total_pages: totalPages,
    rows,
  });
}

export async function handleMe(c: AppContext): Promise<Response> {
  const user = c.get("user");
  const db = c.env.DB;
  const now = Date.now();

  const tokensValue = user.tokens_in + user.tokens_out;
  const [tokensRank, bestRank, allUsersTotal] = await Promise.all([
    rankFor(db, "hidden = 0", "(tokens_in + tokens_out) > ?", [tokensValue]),
    rankFor(db, "hidden = 0", "best_survival_ms > ?", [user.best_survival_ms]),
    countFor(db, "hidden = 0"),
  ]);
  const tokensTotal = allUsersTotal;
  const bestTotal = allUsersTotal;

  let survivalCurrent: { rank: number; total: number } | null = null;
  if (user.pet_birthday !== null && user.last_sync_at !== null && now - user.last_sync_at < STALE_MS) {
    const myAge = now - user.pet_birthday;
    const [rank, total] = await Promise.all([
      rankFor(
        db,
        "hidden = 0",
        "pet_birthday IS NOT NULL AND last_sync_at IS NOT NULL AND last_sync_at >= ? AND (? - pet_birthday) > ?",
        [now - STALE_MS, now, myAge]
      ),
      countFor(db, "hidden = 0 AND pet_birthday IS NOT NULL AND last_sync_at IS NOT NULL AND last_sync_at >= ?", [
        now - STALE_MS,
      ]),
    ]);
    survivalCurrent = { rank, total };
  }

  return c.json(
    {
      id: user.id,
      login: user.login,
      avatar_url: user.avatar_url,
      hidden: user.hidden === 1,
      flagged: user.flagged === 1,
      totals: {
        tokens_in: user.tokens_in,
        tokens_out: user.tokens_out,
        sessions: user.sessions,
        tools_used: user.tools_used,
      },
      pet:
        user.pet_birthday !== null
          ? {
              uid: user.pet_uid,
              species: user.pet_species,
              name: user.pet_name,
              birthday_ms: user.pet_birthday,
              xp: user.pet_xp,
            }
          : null,
      best: {
        survival_ms: user.best_survival_ms,
        species: user.best_pet_species,
        name: user.best_pet_name,
      },
      ranks: {
        tokens: { rank: tokensRank, total: tokensTotal },
        survival_current: survivalCurrent,
        survival_best: { rank: bestRank, total: bestTotal },
      },
      last_sync_at: user.last_sync_at,
    },
    200,
    { "Cache-Control": "no-store" }
  );
}

export async function handleDeleteMe(c: AppContext): Promise<Response> {
  const user = c.get("user");
  await c.env.DB.prepare("DELETE FROM users WHERE id = ?").bind(user.id).run();
  return c.json({ ok: true }, 200, { "Cache-Control": "no-store" });
}

async function rankFor(db: D1Database, extraWhere: string, gtCondition: string, gtArgs: unknown[]): Promise<number> {
  const row = await db
    .prepare(`SELECT COUNT(*) as cnt FROM users WHERE ${extraWhere} AND ${gtCondition}`)
    .bind(...gtArgs)
    .first<{ cnt: number }>();
  return (row?.cnt ?? 0) + 1;
}

async function countFor(db: D1Database, whereSql: string, args: unknown[] = []): Promise<number> {
  const row = await db
    .prepare(`SELECT COUNT(*) as cnt FROM users WHERE ${whereSql}`)
    .bind(...args)
    .first<{ cnt: number }>();
  return row?.cnt ?? 0;
}
