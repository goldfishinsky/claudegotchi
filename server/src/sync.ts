import type { Context } from "hono";
import type { Env, ModelAbsolute, SyncBest, SyncPet, SyncRequestBody, Variables } from "./types";

const RATE_LIMIT_MS = 15 * 60 * 1000;
const TOKEN_CAP_PER_HOUR = 100_000_000;
const MAX_BODY_BYTES = 32 * 1024;
const MAX_NAME_LEN = 40;
const MAX_SPECIES_LEN = 40;
const MAX_PET_AGE_MS = 20 * 365 * 24 * 60 * 60 * 1000;
const MODEL_NAME_RE = /^[A-Za-z0-9._:/-]{1,64}$/;
const PLATFORM_RE = /^[a-z0-9-]{1,32}$/;

type AppContext = Context<{ Bindings: Env; Variables: Variables }>;

export async function handleSync(c: AppContext): Promise<Response> {
  const user = c.get("user");

  const raw = await c.req.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) {
    return c.json({ error: "payload_too_large" }, 413);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }

  if (!isValidBody(parsed)) {
    return c.json({ error: "invalid_body" }, 400);
  }
  const body = parsed;

  const now = Date.now();
  let clamped = false;

  const platformValid = PLATFORM_RE.test(body.platform);
  if (!platformValid) clamped = true;
  const platform = platformValid ? body.platform : user.platform;

  const totals = {
    tokens_in: Math.max(user.tokens_in, sanitizeCount(body.totals.tokens_in)),
    tokens_out: Math.max(user.tokens_out, sanitizeCount(body.totals.tokens_out)),
    sessions: Math.max(user.sessions, sanitizeCount(body.totals.sessions)),
    tools_used: Math.max(user.tools_used, sanitizeCount(body.totals.tools_used)),
  };

  const deltaIn = totals.tokens_in - user.tokens_in;
  const deltaOut = totals.tokens_out - user.tokens_out;
  const totalDelta = deltaIn + deltaOut;
  let flagged = user.flagged;
  // First-ever sync has no prior baseline to rate a delta against, so the cap is skipped.
  if (totalDelta > 0 && user.last_sync_at !== null) {
    const hoursSinceLast = Math.max(1, (now - user.last_sync_at) / 3_600_000);
    const cap = TOKEN_CAP_PER_HOUR * hoursSinceLast;
    if (totalDelta > cap) {
      const scale = cap / totalDelta;
      totals.tokens_in = user.tokens_in + Math.floor(deltaIn * scale);
      totals.tokens_out = user.tokens_out + Math.floor(deltaOut * scale);
      flagged = 1;
      clamped = true;
    }
  }

  let pet: SyncPet | null = null;
  if (body.pet) {
    let birthday = sanitizeCount(body.pet.birthday_ms);
    if (birthday > now) {
      birthday = now;
      clamped = true;
    }
    if (birthday < now - MAX_PET_AGE_MS) {
      birthday = now - MAX_PET_AGE_MS;
      clamped = true;
    }
    const uid = body.pet.uid.slice(0, 64);
    if (uid !== body.pet.uid) clamped = true;
    const species = truncate(body.pet.species, MAX_SPECIES_LEN) ?? "";
    if (species !== body.pet.species) clamped = true;
    const rawPetName = body.pet.name ?? null;
    const name = truncate(rawPetName, MAX_NAME_LEN);
    if (name !== rawPetName) clamped = true;
    pet = { uid, species, name, birthday_ms: birthday, xp: Math.max(0, sanitizeCount(body.pet.xp)) };
  }

  const bestCandidates: SyncBest[] = [
    { survival_ms: user.best_survival_ms, species: user.best_pet_species ?? "", name: user.best_pet_name },
  ];
  if (body.best) {
    let survivalMs = Math.max(0, sanitizeCount(body.best.survival_ms));
    if (survivalMs > MAX_PET_AGE_MS) {
      survivalMs = MAX_PET_AGE_MS;
      clamped = true;
    }
    const species = truncate(body.best.species, MAX_SPECIES_LEN) ?? "";
    if (species !== body.best.species) clamped = true;
    const rawBestName = body.best.name ?? null;
    const name = truncate(rawBestName, MAX_NAME_LEN);
    if (name !== rawBestName) clamped = true;
    bestCandidates.push({ survival_ms: survivalMs, species, name });
  }
  if (pet) {
    bestCandidates.push({ survival_ms: Math.max(0, now - pet.birthday_ms), species: pet.species, name: pet.name });
  }
  const best = bestCandidates.reduce((a, b) => (b.survival_ms > a.survival_ms ? b : a));

  const storedModels = safeParseModels(user.models_json);
  const newModels: Record<string, ModelAbsolute> = { ...storedModels };
  const modelStatements: D1PreparedStatement[] = [];

  for (const [name, reported] of Object.entries(body.models)) {
    if (!MODEL_NAME_RE.test(name) || !isModelAbsolute(reported)) {
      clamped = true;
      continue;
    }
    const baseline = storedModels[name] ?? { in: 0, out: 0, calls: 0 };
    const reportedIn = sanitizeCount(reported.in);
    const reportedOut = sanitizeCount(reported.out);
    const reportedCalls = sanitizeCount(reported.calls);
    newModels[name] = { in: reportedIn, out: reportedOut, calls: reportedCalls };

    const modelDeltaIn = Math.max(0, reportedIn - baseline.in);
    const modelDeltaOut = Math.max(0, reportedOut - baseline.out);
    const modelDeltaCalls = Math.max(0, reportedCalls - baseline.calls);
    if (modelDeltaIn === 0 && modelDeltaOut === 0 && modelDeltaCalls === 0) continue;

    modelStatements.push(
      c.env.DB.prepare(
        `INSERT INTO model_stats (platform, model, tokens_in, tokens_out, calls, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(platform, model) DO UPDATE SET
           tokens_in = tokens_in + excluded.tokens_in,
           tokens_out = tokens_out + excluded.tokens_out,
           calls = calls + excluded.calls,
           updated_at = excluded.updated_at`
      ).bind(platform, name, modelDeltaIn, modelDeltaOut, modelDeltaCalls, now)
    );
  }

  const petUnchanged =
    (pet === null && user.pet_birthday === null) ||
    (pet !== null &&
      user.pet_uid === pet.uid &&
      user.pet_species === pet.species &&
      user.pet_name === pet.name &&
      user.pet_birthday === pet.birthday_ms &&
      user.pet_xp === pet.xp);
  const bestUnchanged =
    best.survival_ms === user.best_survival_ms &&
    best.species === (user.best_pet_species ?? "") &&
    best.name === user.best_pet_name;
  const totalsUnchanged =
    totals.tokens_in === user.tokens_in &&
    totals.tokens_out === user.tokens_out &&
    totals.sessions === user.sessions &&
    totals.tools_used === user.tools_used;
  const isNoOp =
    petUnchanged &&
    bestUnchanged &&
    totalsUnchanged &&
    platform === user.platform &&
    flagged === user.flagged &&
    modelStatements.length === 0;

  if (!isNoOp && user.last_sync_at !== null && now - user.last_sync_at < RATE_LIMIT_MS) {
    return c.json({ error: "rate_limited", retry_after_ms: RATE_LIMIT_MS - (now - user.last_sync_at) }, 429);
  }

  if (!isNoOp) {
    await c.env.DB.batch([
      c.env.DB.prepare(
        `UPDATE users SET
           platform = ?, tokens_in = ?, tokens_out = ?, sessions = ?, tools_used = ?,
           pet_uid = ?, pet_species = ?, pet_name = ?, pet_birthday = ?, pet_xp = ?,
           best_survival_ms = ?, best_pet_species = ?, best_pet_name = ?,
           models_json = ?, flagged = ?, last_sync_at = ?
         WHERE id = ?`
      ).bind(
        platform,
        totals.tokens_in,
        totals.tokens_out,
        totals.sessions,
        totals.tools_used,
        pet ? pet.uid : null,
        pet ? pet.species : null,
        pet ? pet.name : null,
        pet ? pet.birthday_ms : null,
        pet ? pet.xp : 0,
        best.survival_ms,
        best.species,
        best.name,
        JSON.stringify(newModels),
        flagged,
        now,
        user.id
      ),
      ...modelStatements,
    ]);
  }

  const effectiveLastSync = isNoOp ? user.last_sync_at : now;
  const nextSyncAfterMs = effectiveLastSync === null ? 0 : Math.max(0, RATE_LIMIT_MS - (now - effectiveLastSync));

  return c.json({ ok: true, clamped: isNoOp ? false : clamped, next_sync_after_ms: nextSyncAfterMs });
}

function sanitizeCount(n: unknown): number {
  const v = typeof n === "number" && Number.isFinite(n) ? Math.floor(n) : 0;
  return v < 0 ? 0 : v;
}

function truncate(s: string | null, max: number): string | null {
  if (s === null) return null;
  return s.length > max ? s.slice(0, max) : s;
}

function isModelAbsolute(v: unknown): v is ModelAbsolute {
  return (
    typeof v === "object" &&
    v !== null &&
    typeof (v as ModelAbsolute).in === "number" &&
    typeof (v as ModelAbsolute).out === "number" &&
    typeof (v as ModelAbsolute).calls === "number"
  );
}

function safeParseModels(json: string): Record<string, ModelAbsolute> {
  try {
    const parsed = JSON.parse(json);
    return typeof parsed === "object" && parsed !== null ? parsed : {};
  } catch {
    return {};
  }
}

function isValidBody(body: unknown): body is SyncRequestBody {
  if (typeof body !== "object" || body === null) return false;
  const b = body as Record<string, unknown>;
  if (typeof b.platform !== "string") return false;
  if (typeof b.totals !== "object" || b.totals === null) return false;
  const totals = b.totals as Record<string, unknown>;
  for (const key of ["tokens_in", "tokens_out", "sessions", "tools_used"]) {
    if (typeof totals[key] !== "number") return false;
  }
  if (b.pet !== null && b.pet !== undefined) {
    if (typeof b.pet !== "object") return false;
    const pet = b.pet as Record<string, unknown>;
    if (typeof pet.uid !== "string") return false;
    if (typeof pet.species !== "string") return false;
    if (pet.name != null && typeof pet.name !== "string") return false;
    if (typeof pet.birthday_ms !== "number") return false;
    if (typeof pet.xp !== "number") return false;
  }
  if (b.best !== null && b.best !== undefined) {
    if (typeof b.best !== "object") return false;
    const best = b.best as Record<string, unknown>;
    if (typeof best.survival_ms !== "number") return false;
    if (typeof best.species !== "string") return false;
    if (best.name != null && typeof best.name !== "string") return false;
  }
  if (typeof b.models !== "object" || b.models === null) return false;
  return true;
}
