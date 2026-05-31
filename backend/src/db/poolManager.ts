/**
 * Schema-per-academy multi-tenancy.
 *
 * All academies share a single PostgreSQL database (and a single pg.Pool).
 * Each academy's data lives in its own schema named after the academy slug.
 *
 * Queries are routed by temporarily setting search_path on the checked-out
 * client, then resetting it before the client is returned to the pool.
 * This is safe even with connection pooling because the reset always runs
 * in the finally block.
 */

import { Pool, PoolClient } from 'pg';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: { rejectUnauthorized: false },
  max: 10,                   // headroom for concurrent academy queries + transactions
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
});

pool.on('error', (err) => {
  console.error('[Pool] Unexpected error on idle client:', err.message);
});

// ── Schema helpers ────────────────────────────────────────────────────────────

/** Validate slug — only allow alphanumeric + underscore to prevent SQL injection */
function assertSafeSlug(slug: string): void {
  if (!/^[a-z0-9_]{1,63}$/.test(slug)) {
    throw new Error(`Invalid academy slug: "${slug}"`);
  }
}

async function withSchema<T>(
  slug: string,
  fn: (client: PoolClient) => Promise<T>
): Promise<T> {
  assertSafeSlug(slug);
  const client = await pool.connect();
  try {
    // The search_path MUST be set inside the same transaction as the query.
    // Neon's connection pooler (PgBouncer) runs in *transaction* pooling mode:
    // a session-level `SET search_path` and the query that follows can be
    // routed to different backend connections, leaving the query pointed at
    // `public` — where the per-academy tables don't exist (intermittent
    // `relation "..." does not exist` 500s, or silent cross-tenant reads for
    // tables that happen to exist in public). BEGIN pins one backend for the
    // whole transaction; SET LOCAL scopes the path to it and auto-resets at
    // COMMIT, so no manual reset is needed.
    await client.query(`BEGIN; SET LOCAL search_path TO "${slug}", public;`);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch (_) {}
    throw err;
  } finally {
    client.release();
  }
}

// ── Public query helpers ──────────────────────────────────────────────────────

export async function academyQuery<T = Record<string, unknown>>(
  slug: string,
  sql: string,
  params?: unknown[]
): Promise<T[]> {
  return withSchema(slug, async (client) => {
    const result = await client.query(sql, params);
    return result.rows as T[];
  });
}

export async function academyQueryOne<T = Record<string, unknown>>(
  slug: string,
  sql: string,
  params?: unknown[]
): Promise<T | null> {
  const rows = await academyQuery<T>(slug, sql, params);
  return rows[0] ?? null;
}

export async function academyTransaction(
  slug: string,
  fn: (client: PoolClient) => Promise<void>
): Promise<void> {
  assertSafeSlug(slug);
  const client = await pool.connect();
  try {
    // SET LOCAL goes *inside* the transaction so the search_path is pinned to
    // the same pooled backend that runs fn()'s statements (see withSchema for
    // why a session-level SET is unsafe under PgBouncer transaction pooling).
    await client.query(`BEGIN; SET LOCAL search_path TO "${slug}", public;`);
    await fn(client);
    await client.query('COMMIT');
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch (_) {}
    throw err;
  } finally {
    client.release();
  }
}

/** Run a single mutating SQL statement and return affected row count + rows. */
export async function academyExec<T = Record<string, unknown>>(
  slug: string,
  sql: string,
  params?: unknown[]
): Promise<{ rows: T[]; rowCount: number }> {
  return withSchema(slug, async (client) => {
    const result = await client.query(sql, params);
    return { rows: result.rows as T[], rowCount: result.rowCount ?? 0 };
  });
}

/** Direct access to the shared pool (for schema creation, migrations). */
export { pool as sharedPool };
