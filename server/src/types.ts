export interface Env {
  DB: D1Database;
  GITHUB_CLIENT_ID: string;
}

export interface UserRow {
  id: number;
  login: string;
  avatar_url: string | null;
  platform: string;
  hidden: number;
  token_hash: string | null;
  token_created_at: number | null;
  tokens_in: number;
  tokens_out: number;
  sessions: number;
  tools_used: number;
  pet_uid: string | null;
  pet_species: string | null;
  pet_name: string | null;
  pet_birthday: number | null;
  pet_xp: number;
  best_survival_ms: number;
  best_pet_species: string | null;
  best_pet_name: string | null;
  models_json: string;
  flagged: number;
  flag_note: string | null;
  created_at: number;
  last_sync_at: number | null;
}

export interface ModelAbsolute {
  in: number;
  out: number;
  calls: number;
}

export interface SyncTotals {
  tokens_in: number;
  tokens_out: number;
  sessions: number;
  tools_used: number;
}

export interface SyncPet {
  uid: string;
  species: string;
  name?: string | null;
  birthday_ms: number;
  xp: number;
}

export interface SyncBest {
  survival_ms: number;
  species: string;
  name?: string | null;
}

export interface SyncRequestBody {
  platform: string;
  totals: SyncTotals;
  pet?: SyncPet | null;
  best?: SyncBest | null;
  models: Record<string, ModelAbsolute>;
}

export type Variables = {
  user: UserRow;
};
