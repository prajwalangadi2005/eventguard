/**
 * lib/db/postgres.ts
 *
 * LEARNING NOTE:
 * This file creates a "connection pool" to PostgreSQL.
 * A pool = a group of pre-opened database connections kept ready.
 * Instead of opening a new connection for every request (slow),
 * the pool reuses existing connections (fast).
 *
 * We use a global variable to avoid creating a new pool on every
 * hot-reload during development (Next.js restarts modules often).
 */

import { Pool } from 'pg';

// Declare a global pool variable so it survives Next.js hot-reloads
declare global {
  // eslint-disable-next-line no-var
  var __pgPool: Pool | undefined;
}

function createPool(): Pool {
  return new Pool({
    connectionString: process.env.DATABASE_URL,
    max: 10,              // maximum 10 simultaneous connections
    idleTimeoutMillis: 30000,   // close idle connections after 30s
    connectionTimeoutMillis: 5000, // fail fast if can't connect in 5s
  });
}

// In development: reuse the pool across hot-reloads
// In production:  create a fresh pool each time
const pool = global.__pgPool ?? createPool();

if (process.env.NODE_ENV !== 'production') {
  global.__pgPool = pool;
}

export default pool;

/**
 * Helper: run a query and get rows back.
 * Usage:
 *   const rows = await query('SELECT * FROM users WHERE email = $1', [email]);
 *
 * LEARNING NOTE: $1, $2, ... are parameterized placeholders.
 * NEVER concatenate user input into SQL strings — that's SQL injection.
 * Always use $1, $2 style parameters.
 */
export async function query<T = Record<string, unknown>>(
  text: string,
  params?: unknown[]
): Promise<T[]> {
  const result = await pool.query(text, params);
  return result.rows as T[];
}

/**
 * Helper: get a client for manual transactions.
 * Usage:
 *   const client = await getClient();
 *   try {
 *     await client.query('BEGIN');
 *     ...
 *     await client.query('COMMIT');
 *   } catch {
 *     await client.query('ROLLBACK');
 *   } finally {
 *     client.release(); // ALWAYS release back to pool
 *   }
 */
export async function getClient() {
  return pool.connect();
}
