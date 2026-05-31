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
  max: 5,                    // free-tier: keep memory footprint small
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
    await client.query(`SET search_path TO "${slug}", public`);
    return await fn(client);
  } finally {
    // Always reset before returning to pool
    try { await client.query('SET search_path TO public'); } catch (_) {}
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
    await client.query(`SET search_path TO "${slug}", public`);
    await client.query('BEGIN');
    await fn(client);
    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    try { await client.query('SET search_path TO public'); } catch (_) {}
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
