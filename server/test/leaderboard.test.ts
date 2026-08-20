import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, it } from "vitest";
import app from "../src/index";
import type { Env, UserRow } from "../src/types";

const testEnv = env as unknown as Env;

// D1 storage and caches.default persist across tests within this file (isolation
// is per test file, not per test), so both are reset/keyed per test explicitly.
beforeEach(async () => {
  await testEnv.DB.prepare("DELETE FROM users").run();
});

async function callWorker(url: string, init?: RequestInit): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await app.fetch(new Request(url, init), testEnv, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

async function insertUser(overrides: Partial<UserRow> & { id: number }): Promise<void> {
  const now = Date.now();
  const defaults: UserRow = {
    id: overrides.id,
    login: `user${overrides.id}`,
    avatar_url: null,
    platform: "claude-code",
    hidden: 0,
    token_hash: null,
    token_created_at: null,
    tokens_in: 0,
    tokens_out: 0,
    sessions: 0,
    tools_used: 0,
    pet_uid: null,
    pet_species: null,
    pet_name: null,
    pet_birthday: null,
    pet_xp: 0,
    best_survival_ms: 0,
    best_pet_species: null,
    best_pet_name: null,
    models_json: "{}",
    flagged: 0,
    flag_note: null,
    created_at: now,
    last_sync_at: null,
  };
  const row: UserRow = { ...defaults, ...overrides };
  const columns = Object.keys(row);
  await testEnv.DB.prepare(
    `INSERT INTO users (${columns.join(", ")}) VALUES (${columns.map(() => "?").join(", ")})`
  )
    .bind(...columns.map((k) => (row as unknown as Record<string, unknown>)[k]))
    .run();
}

// Each test uses its own host so caches.default (which keys on the full request
// URL) never serves another test's cached response for an identical query string.
function getLeaderboard(host: string, query: string): Promise<Response> {
  return callWorker(`https://${host}.example.com/v1/leaderboard?${query}`);
}

it("orders the tokens board by total tokens descending with correct ranks", async ({ expect }) => {
  await insertUser({ id: 1, login: "low", tokens_in: 10, tokens_out: 0 });
  await insertUser({ id: 2, login: "high", tokens_in: 1000, tokens_out: 0 });
  await insertUser({ id: 3, login: "mid", tokens_in: 100, tokens_out: 0 });

  const response = await getLeaderboard("t1", "board=tokens&platform=all&page=1");
  expect(response.status).toBe(200);
  const body = (await response.json()) as {
    rows: { login: string; rank: number; value?: number; value_ms?: number; pet: unknown }[];
    total: number;
  };

  expect(body.rows.map((r) => r.login)).toEqual(["high", "mid", "low"]);
  expect(body.rows.map((r) => r.rank)).toEqual([1, 2, 3]);
  expect(body.rows[0].value).toBe(1000);
  expect(body.rows[0].value_ms).toBeUndefined();
  expect(body.rows[0].pet).toBeNull();
  expect(body.total).toBe(3);
});

it("excludes hidden users from the tokens board", async ({ expect }) => {
  await insertUser({ id: 1, login: "visible", tokens_in: 100 });
  await insertUser({ id: 2, login: "ghost", tokens_in: 999999, hidden: 1 });

  const response = await getLeaderboard("t2", "board=tokens&platform=all&page=1");
  const body = (await response.json()) as { rows: { login: string }[]; total: number };

  expect(body.rows.map((r) => r.login)).toEqual(["visible"]);
  expect(body.total).toBe(1);
});

it("uses per-platform totals when filtering a dual-platform user", async ({ expect }) => {
  await insertUser({ id: 1, login: "dual", tokens_in: 1000, tokens_out: 0 });
  await testEnv.DB.prepare(
    `INSERT INTO user_platform_stats
       (user_id, platform, tokens_in, tokens_out, models_json, updated_at)
     VALUES (?, ?, ?, 0, '{}', ?), (?, ?, ?, 0, '{}', ?)`
  ).bind(1, "claude-code", 100, Date.now(), 1, "codex", 900, Date.now()).run();

  const claudeResponse = await getLeaderboard("dual-claude", "board=tokens&platform=claude-code&page=1");
  const codexResponse = await getLeaderboard("dual-codex", "board=tokens&platform=codex&page=1");
  const claude = (await claudeResponse.json()) as { rows: { login: string; value: number }[] };
  const codex = (await codexResponse.json()) as { rows: { login: string; value: number }[] };

  expect(claude.rows).toEqual([expect.objectContaining({ login: "dual", value: 100 })]);
  expect(codex.rows).toEqual([expect.objectContaining({ login: "dual", value: 900 })]);
});

it("orders survival_best by best_survival_ms descending using the historical best pet", async ({ expect }) => {
  await insertUser({ id: 1, login: "champion", best_survival_ms: 999_000, best_pet_species: "dragon", best_pet_name: "Rex" });
  await insertUser({ id: 2, login: "rookie", best_survival_ms: 1_000 });

  const response = await getLeaderboard("t3", "board=survival_best&platform=all&page=1");
  const body = (await response.json()) as {
    rows: { login: string; pet: { species: string; name: string | null } | null; value_ms?: number; value?: number }[];
  };

  expect(body.rows.map((r) => r.login)).toEqual(["champion", "rookie"]);
  expect(body.rows[0].pet).toEqual({ species: "dragon", name: "Rex" });
  expect(body.rows[0].value_ms).toBe(999_000);
  expect(body.rows[0].value).toBeUndefined();
  expect(body.rows[1].pet).toBeNull();
});

it("excludes stale users from survival_current and orders by current pet age descending", async ({ expect }) => {
  const now = Date.now();
  await insertUser({
    id: 1,
    login: "fresh-old-pet",
    pet_species: "frog",
    pet_name: null,
    pet_birthday: now - 10 * 24 * 60 * 60 * 1000,
    last_sync_at: now - 60 * 1000,
  });
  await insertUser({
    id: 2,
    login: "stale",
    pet_birthday: now - 30 * 24 * 60 * 60 * 1000,
    last_sync_at: now - 8 * 24 * 60 * 60 * 1000,
  });
  await insertUser({
    id: 3,
    login: "fresh-young-pet",
    pet_birthday: now - 2 * 24 * 60 * 60 * 1000,
    last_sync_at: now - 60 * 1000,
  });
  await insertUser({ id: 4, login: "no-pet" });

  const response = await getLeaderboard("t4", "board=survival_current&platform=all&page=1");
  const body = (await response.json()) as {
    rows: { login: string; pet: { species: string; name: string | null } | null; value_ms?: number; value?: number }[];
    total: number;
  };

  expect(body.rows.map((r) => r.login)).toEqual(["fresh-old-pet", "fresh-young-pet"]);
  expect(body.total).toBe(2);
  expect(body.rows[0].pet).toEqual({ species: "frog", name: null });
  expect(body.rows[0].value_ms).toBeGreaterThanOrEqual(10 * 24 * 60 * 60 * 1000);
  expect(body.rows[0].value).toBeUndefined();
});

it("paginates results at 50 per page and caps at 10 pages", async ({ expect }) => {
  for (let i = 0; i < 60; i++) {
    await insertUser({ id: 1000 + i, login: `user${i}`, tokens_in: 1000 - i });
  }

  const page1Response = await getLeaderboard("t5", "board=tokens&platform=all&page=1");
  const page2Response = await getLeaderboard("t5", "board=tokens&platform=all&page=2");
  const page1 = (await page1Response.json()) as {
    rows: { rank: number; login: string }[];
    total: number;
    total_pages: number;
  };
  const page2 = (await page2Response.json()) as { rows: { rank: number; login: string }[] };

  expect(page1.rows.length).toBe(50);
  expect(page2.rows.length).toBe(10);
  expect(page1.total).toBe(60);
  expect(page1.total_pages).toBe(2);
  expect(page1.rows[0].rank).toBe(1);
  expect(page1.rows[0].login).toBe("user0");
  expect(page2.rows[0].rank).toBe(51);

  const page11 = await getLeaderboard("t5", "board=tokens&platform=all&page=11");
  expect(page11.status).toBe(400);
});
