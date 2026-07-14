import { applyD1Migrations, env } from "cloudflare:test";

interface TestEnv {
  DB: D1Database;
  TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
}

const testEnv = env as unknown as TestEnv;

await applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS);
