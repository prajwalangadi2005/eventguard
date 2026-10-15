/**
 * app/api/auth/login/route.ts
 *
 * POST /api/auth/login
 *
 * WHAT THIS DOES:
 * 1. Takes { email, password } from the client request.
 * 2. Looks up the user in PostgreSQL by email.
 * 3. Uses bcrypt to securely compare the entered password against the stored hash.
 * 4. If credentials match, generates a signed JWT and attaches it as an HttpOnly cookie.
 * 5. Returns the user's profile info (excluding password hash).
 */

import { NextRequest } from 'next/server';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { query } from '@/lib/db/postgres';
import { signToken } from '@/lib/auth';

// Validate input with Zod
const loginSchema = z.object({
  email: z.string().email('Invalid email address'),
  password: z.string().min(1, 'Password is required'),
});

interface UserRecord {
  user_id: number;
  name: string;
  email: string;
  password_hash: string;
  role: 'admin' | 'organizer' | 'attendee' | 'gate_staff';
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const parsed = loginSchema.safeParse(body);

    if (!parsed.success) {
      return Response.json(
        { error: 'Invalid input', details: parsed.error.flatten().fieldErrors },
        { status: 400 }
      );
    }

    const { email, password } = parsed.data;

    // 1. Look up user by email
    const rows = await query<UserRecord>(
      `SELECT user_id, name, email, password_hash, role
       FROM users
       WHERE email = $1`,
      [email]
    );

    if (rows.length === 0) {
      // Security best practice: don't reveal whether email exists or not
      return Response.json(
        { error: 'Invalid email or password' },
        { status: 401 }
      );
    }

    const user = rows[0];

    // 2. Compare password with bcrypt hash
    const isPasswordValid = await bcrypt.compare(password, user.password_hash);
    if (!isPasswordValid) {
      return Response.json(
        { error: 'Invalid email or password' },
        { status: 401 }
      );
    }

    // 3. Create signed JWT
    const token = signToken({
      user_id: user.user_id,
      email: user.email,
      role: user.role,
    });

    // 4. Return user profile and set HttpOnly session cookie
    const response = Response.json({
      message: 'Logged in successfully',
      user: {
        user_id: user.user_id,
        name: user.name,
        email: user.email,
        role: user.role,
      },
    });

    response.headers.set(
      'Set-Cookie',
      `token=${token}; HttpOnly; Path=/; Max-Age=${7 * 24 * 60 * 60}; SameSite=Lax`
    );

    return response;
  } catch (err: unknown) {
    console.error('Login error:', err);
    return Response.json({ error: 'Internal server error' }, { status: 500 });
  }
}
