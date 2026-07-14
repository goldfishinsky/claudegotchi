import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, it } from "vitest";
import app from "../src/index";
import { sha256Hex } from "../src/db";
import type { Env, UserRow } from "../src/types";

const testEnv = env as unknown as Env;

// D1 storage persists across tests within this file (isolation is per test file, not per test).
beforeEach(async () => {
  await testEnv.DB.prepare("DELETE FROM users").run();
  await testEnv.DB.prepare("DELETE FROM model_stats").run();
});

async function callWorker(url: string, init?: RequestInit): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await app.fetch(new Request(url, init), testEnv, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

async function insertUser(overrides: Partial<UserRow> & { id: number }): Promise<{ id: number; token: string }> {
  const token = `test-token-${overrides.id}`;
  const tokenHash = await sha256Hex(token);
  const now = Date.now();
  const defaults: UserRow = {
    id: overrides.id,
    login: `user${overrides.id}`,
    avatar_url: null,
    platform: "claude-code",
    hidden: 0,
    token_hash: tokenHash,
    token_created_at: now,
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
  const row: UserRow = { ...defaults, ...overrides, token_hash: tokenHash };
  const columns = Object.keys(row);
  await testEnv.DB.prepare(
    `INSERT INTO users (${columns.join(", ")}) VALUES (${columns.map(() => "?").join(", ")})`
  )
    .bind(...columns.map((k) => (row as unknown as Record<string, unknown>)[k]))
    .run();
  return { id: overrides.id, token };
}

function syncRequest(token: string, body: unknown): Promise<Response> {
  return callWorker("https://example.com/v1/sync", {
    method: "POST",
    headers: { "content-type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
}

it("keeps totals monotonic when a later sync reports smaller values", async ({ expect }) => {
  const { token } = await insertUser({ id: 1, tokens_in: 5000, tokens_out: 2000, sessions: 4, tools_used: 8 });

  const response = await syncRequest(token, {
    platform: "claude-code",
    totals: { tokens_in: 10, tokens_out: 5, sessions: 1, tools_used: 1 },
    pet: null,
    best: null,
    models: {},
  });
  expect(response.status).toBe(200);
  const body = (await response.json()) as { ok: boolean; clamped: boolean };
  expect(body.ok).toBe(true);
  expect(body.clamped).toBe(false);

  const row = await testEnv.DB.prepare(
    "SELECT tokens_in, tokens_out, sessions, tools_used, flagged FROM users WHERE id = ?"
  )
    .bind(1)
    .first<{ tokens_in: number; tokens_out: number; sessions: number; tools_used: number; flagged: number }>();
  expect(row?.tokens_in).toBe(5000);
  expect(row?.tokens_out).toBe(2000);
  expect(row?.sessions).toBe(4);
  expect(row?.tools_used).toBe(8);
  expect(row?.flagged).toBe(0);
});

it("clamps an oversized token delta to the hourly cap and flags the user", async ({ expect }) => {
  const twoHoursAgo = Date.now() - 2 * 60 * 60 * 1000;
  const { token } = await insertUser({ id: 2, last_sync_at: twoHoursAgo });

  const hugeIn = 500_000_000_000;
  const response = await syncRequest(token, {
    platform: "claude-code",
    totals: { tokens_in: hugeIn, tokens_out: 0, sessions: 0, tools_used: 0 },
    pet: null,
    best: null,
    models: {},
  });
  expect(response.status).toBe(200);
  const body = (await response.json()) as { ok: boolean; clamped: boolean };
  expect(body.clamped).toBe(true);

  const row = await testEnv.DB.prepare("SELECT tokens_in, flagged FROM users WHERE id = ?")
    .bind(2)
    .first<{ tokens_in: number; flagged: number }>();
  expect(row?.flagged).toBe(1);
  // Cap is 100M/hour since last sync; allow generous drift for test execution time.
  expect(row?.tokens_in).toBeGreaterThanOrEqual(100_000_000 * 2);
  expect(row?.tokens_in).toBeLessThan(100_000_000 * 2 + 10_000_000);
});

it("does not double count model_stats when the same absolute payload is sent twice", async ({ expect }) => {
  const { token } = await insertUser({ id: 3 });

  const payload = {
    platform: "claude-code",
    totals: { tokens_in: 100, tokens_out: 50, sessions: 1, tools_used: 1 },
    pet: null,
    best: null,
    models: { "claude-sonnet-5": { in: 1000, out: 200, calls: 5 } },
  };

  const first = await syncRequest(token, payload);
  expect(first.status).toBe(200);

  const afterFirst = await testEnv.DB.prepare(
    "SELECT tokens_in, tokens_out, calls FROM model_stats WHERE platform = ? AND model = ?"
  )
    .bind("claude-code", "claude-sonnet-5")
    .first<{ tokens_in: number; tokens_out: number; calls: number }>();
  expect(afterFirst).toEqual({ tokens_in: 1000, tokens_out: 200, calls: 5 });

  const second = await syncRequest(token, payload);
  expect(second.status).toBe(200);
  const secondBody = (await second.json()) as { ok: boolean; clamped: boolean };
  expect(secondBody.ok).toBe(true);
  expect(secondBody.clamped).toBe(false);

  const afterSecond = await testEnv.DB.prepare(
    "SELECT tokens_in, tokens_out, calls FROM model_stats WHERE platform = ? AND model = ?"
  )
    .bind("claude-code", "claude-sonnet-5")
    .first<{ tokens_in: number; tokens_out: number; calls: number }>();
  expect(afterSecond).toEqual({ tokens_in: 1000, tokens_out: 200, calls: 5 });
});

it("accumulates model_stats deltas correctly across two different absolute payloads", async ({ expect }) => {
  const { token } = await insertUser({ id: 4 });

  await syncRequest(token, {
    platform: "claude-code",
    totals: { tokens_in: 0, tokens_out: 0, sessions: 0, tools_used: 0 },
    pet: null,
    best: null,
    models: { "claude-sonnet-5": { in: 1000, out: 200, calls: 5 } },
  });

  await testEnv.DB.prepare("UPDATE users SET last_sync_at = ? WHERE id = ?")
    .bind(Date.now() - 20 * 60 * 1000, 4)
    .run();

  await syncRequest(token, {
    platform: "claude-code",
    totals: { tokens_in: 0, tokens_out: 0, sessions: 0, tools_used: 0 },
    pet: null,
    best: null,
    models: { "claude-sonnet-5": { in: 1500, out: 250, calls: 8 } },
  });

  const row = await testEnv.DB.prepare(
    "SELECT tokens_in, tokens_out, calls FROM model_stats WHERE platform = ? AND model = ?"
  )
    .bind("claude-code", "claude-sonnet-5")
    .first<{ tokens_in: number; tokens_out: number; calls: number }>();
  expect(row).toEqual({ tokens_in: 1500, tokens_out: 250, calls: 8 });
});

it("rejects a second changed sync within 15 minutes with 429 and a positive retry_after_ms", async ({ expect }) => {
  const { token } = await insertUser({ id: 5 });

  const first = await syncRequest(token, {
    platform: "claude-code",
    totals: { tokens_in: 100, tokens_out: 0, sessions: 0, tools_used: 0 },
    pet: null,
    best: null,
    models: {},
  });
  expect(first.status).toBe(200);

  const second = await syncRequest(token, {
    platform: "claude-code",
    totals: { tokens_in: 200, tokens_out: 0, sessions: 0, tools_used: 0 },
    pet: null,
    best: null,
    models: {},
  });
  expect(second.status).toBe(429);
  const body = (await second.json()) as { error: string; retry_after_ms: number };
  expect(body.error).toBe("rate_limited");
  expect(body.retry_after_ms).toBeGreaterThan(0);
  expect(body.retry_after_ms).toBeLessThanOrEqual(15 * 60 * 1000);
});

it("accepts a payload with pet and best keys omitted entirely (Swift encodeIfPresent)", async ({ expect }) => {
  const { token } = await insertUser({ id: 6 });

  const response = await syncRequest(token, {
    platform: "claude-code",
    totals: { tokens_in: 100, tokens_out: 50, sessions: 1, tools_used: 2 },
    models: {},
  });
  expect(response.status).toBe(200);
  const body = (await response.json()) as { ok: boolean; clamped: boolean };
  expect(body.ok).toBe(true);
  expect(body.clamped).toBe(false);

  const row = await testEnv.DB.prepare("SELECT tokens_in, pet_birthday FROM users WHERE id = ?")
    .bind(6)
    .first<{ tokens_in: number; pet_birthday: number | null }>();
  expect(row?.tokens_in).toBe(100);
  expect(row?.pet_birthday).toBeNull();
});

it("accepts a pet with the name key omitted and stores name as NULL without clamping", async ({ expect }) => {
  const { token } = await insertUser({ id: 7 });
  const birthday = Date.now() - 24 * 60 * 60 * 1000;

  const response = await syncRequest(token, {
    platform: "claude-code",
    totals: { tokens_in: 0, tokens_out: 0, sessions: 0, tools_used: 0 },
    pet: { uid: "01JTEST", species: "frog", birthday_ms: birthday, xp: 3 },
    models: {},
  });
  expect(response.status).toBe(200);
  const body = (await response.json()) as { ok: boolean; clamped: boolean };
  expect(body.clamped).toBe(false);

  const row = await testEnv.DB.prepare("SELECT pet_species, pet_name, pet_birthday FROM users WHERE id = ?")
    .bind(7)
    .first<{ pet_species: string; pet_name: string | null; pet_birthday: number }>();
  expect(row?.pet_species).toBe("frog");
  expect(row?.pet_name).toBeNull();
  expect(row?.pet_birthday).toBe(birthday);
});

it("rejects sync requests without a valid bearer token", async ({ expect }) => {
  const response = await callWorker("https://example.com/v1/sync", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ platform: "claude-code", totals: {}, pet: null, best: null, models: {} }),
  });
  expect(response.status).toBe(401);
});
