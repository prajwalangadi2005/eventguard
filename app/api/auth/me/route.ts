/**
 * app/api/auth/me/route.ts
 *
 * GET /api/auth/me
 *
 * WHAT THIS DOES:
 * Returns the currently authenticated user's profile.
 * Reads the JWT cookie, verifies it, and queries the user row from PostgreSQL.
 */

import { NextRequest } from 'next/server';
import { getUser } from '@/lib/auth';
import { query } from '@/lib/db/postgres';

interface UserProfile {
  user_id: number;
  name: string;
  email: string;
  role: string;
  created_at: string;
}

export async function GET(request: NextRequest) {
  try {
    const payload = getUser(request);
    if (!payload) {
      return Response.json({ user: null }, { status: 401 });
    }

    const rows = await query<UserProfile>(
      `SELECT user_id, name, email, role, created_at
       FROM users
       WHERE user_id = $1`,
      [payload.user_id]
    );

    if (rows.length === 0) {
      return Response.json({ user: null }, { status: 404 });
    }

    return Response.json({ user: rows[0] });
  } catch (err: unknown) {
    console.error('Auth check error:', err);
    return Response.json({ error: 'Internal server error' }, { status: 500 });
  }
}
