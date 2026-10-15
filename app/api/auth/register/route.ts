/**
 * app/api/auth/register/route.ts
 *
 * POST /api/auth/register
 *
 * WHAT THIS DOES:
 * Creates a new user account. Takes name/email/password/role,
 * hashes the password with bcrypt, saves to PostgreSQL,
 * then immediately logs the user in by setting a JWT cookie.
 *
 * LEARNING — Request lifecycle:
 * Browser sends POST with JSON body
 *   → Next.js calls this POST() function
 *   → We read + validate the body with Zod
 *   → Hash password with bcrypt (slow by design — makes brute-force hard)
 *   → INSERT into PostgreSQL users table
 *   → Create JWT, set as HttpOnly cookie
 *   → Return 201 with user data (without the password hash!)
 */

import { NextRequest } from 'next/server';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { query } from '@/lib/db/postgres';
import { signToken } from '@/lib/auth';

// ── Zod schema: validate the request body ───────────────────────
// LEARNING: Zod checks types at runtime (TypeScript only checks at compile time).
// This means if someone sends { email: 123 } we catch it here, not in the DB.
const registerSchema = z.object({
  name: z.string().min(1, 'Name is required').max(100),
  email: z.string().email('Invalid email address'),
  password: z.string().min(8, 'Password must be at least 8 characters'),
  // Role defaults to 'attendee'. Only 'admin' can promote users later.
  role: z.enum(['attendee', 'organizer', 'gate_staff']).default('attendee'),
});

// ── Row type returned from our SELECT query ──────────────────────
interface UserRow {
  user_id: number;
  name: string;
  email: string;
  role: string;
  created_at: string;
}

export async function POST(request: NextRequest) {
  try {
    // Step 1: Parse and validate request body
    const body = await request.json();
    const parsed = registerSchema.safeParse(body);

    if (!parsed.success) {
      // Zod gives us a nice error list — send it back
      return Response.json(
        { error: 'Validation failed', details: parsed.error.flatten().fieldErrors },
        { status: 400 }
      );
    }

    const { name, email, password, role } = parsed.data;

    // Step 2: Hash the password
    // LEARNING: bcrypt.hash(password, 10) — the "10" is the salt rounds.
    // Higher = slower hashing = harder to brute-force.
    // 10 is the industry standard (~100ms on a modern CPU).
    const password_hash = await bcrypt.hash(password, 10);

    // Step 3: Insert into PostgreSQL
    // LEARNING: $1, $2 etc. are parameterized placeholders.
    // The pg library escapes these safely — zero risk of SQL injection.
    const rows = await query<UserRow>(
      `INSERT INTO users (name, email, password_hash, role)
       VALUES ($1, $2, $3, $4)
       RETURNING user_id, name, email, role, created_at`,
      [name, email, password_hash, role]
    );

    const user = rows[0];

    // Step 4: Create a JWT for the new user
    const token = signToken({
      user_id: user.user_id,
      email: user.email,
      role: user.role as 'admin' | 'organizer' | 'attendee' | 'gate_staff',
    });

    // Step 5: Set the JWT as an HttpOnly cookie and return the user
    // LEARNING: HttpOnly = browser JS cannot read this cookie.
    // This protects against XSS (cross-site scripting) attacks.
    const response = Response.json(
      { message: 'Account created successfully', user },
      { status: 201 }
    );

    response.headers.set(
      'Set-Cookie',
      `token=${token}; HttpOnly; Path=/; Max-Age=${7 * 24 * 60 * 60}; SameSite=Lax`
    );

    return response;

  } catch (err: unknown) {
    // Handle duplicate email (PostgreSQL unique constraint violation)
    // Error code 23505 = unique_violation
    if (
      err &&
      typeof err === 'object' &&
      'code' in err &&
      (err as { code: string }).code === '23505'
    ) {
      return Response.json(
        { error: 'An account with this email already exists' },
        { status: 409 }
      );
    }

    console.error('Register error:', err);
    return Response.json({ error: 'Internal server error' }, { status: 500 });
  }
}
