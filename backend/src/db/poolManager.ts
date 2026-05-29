/**
 * Dynamic pool manager — one pg.Pool per academy Neon branch.
 * Pools are cached by connection string so we never open more than one
 * per academy regardless of how many concurrent requests come in.
 */

import { Pool, PoolClient } from 'pg';
import { queryOne } from './pool';

interface AcademyRow {
  id: string;
  connection_string: string;
}

// connection_string → Pool
const poolCache = new Map<string, Pool>();

export function getPoolForConnection(connectionString: string): Pool {
  if (!poolCache.has(connectionString)) {
    const pool = new Pool({
      connectionString,
      ssl: { rejectUnauthorized: false },
      max: 5,                    // small per-academy pool — Neon free tier limit
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 10_000,
    });
    pool.on('error', (err) => {
      console.error(`[PoolManager] Pool error for connection: ${err.message}`);
    });
    poolCache.set(connectionString, pool);
  }
  return poolCache.get(connectionString)!;
}

export async function getAcademyPool(academyId: string): Promise<Pool> {
  const row = await queryOne<AcademyRow>(
    `SELECT id, connection_string FROM academies WHERE id = $1 AND status = 'active'`,
    [academyId]
  );
  if (!row) throw new Error(`Academy ${academyId} not found or inactive`);
  return getPoolForConnection(row.connection_string);
}

// ── Convenience query helpers (mirror pool.ts API) ────────────────────────────

export async function academyQuery<T = Record<string, unknown>>(
  academyId: string,
  sql: string,
  params?: unknown[]
): Promise<T[]> {
  const pool = await getAcademyPool(academyId);
  const result = await pool.query(sql, params);
  return result.rows as T[];
}

export async function academyQueryOne<T = Record<string, unknown>>(
  academyId: string,
  sql: string,
  params?: unknown[]
): Promise<T | null> {
  const rows = await academyQuery<T>(academyId, sql, params);
  return rows[0] ?? null;
}

export async function academyTransaction(
  academyId: string,
  fn: (client: PoolClient) => Promise<void>
): Promise<void> {
  const pool = await getAcademyPool(academyId);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await fn(client);
    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}
