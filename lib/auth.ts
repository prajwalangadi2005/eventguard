/**
 * lib/auth.ts
 *
 * WHAT THIS FILE DOES:
 * Provides two helpers that every API route will use:
 *   1. signToken(payload)  — creates a JWT (a signed string that proves identity)
 *   2. verifyToken(token)  — checks if the JWT is genuine and not tampered with
 *   3. getUser(request)    — reads the JWT from the request cookie, returns the user
 *
 * LEARNING: What is a JWT?
 * A JWT (JSON Web Token) is a base64-encoded string with 3 parts:
 *   HEADER.PAYLOAD.SIGNATURE
 *
 * Example:
 *   eyJhbGc... . eyJ1c2Vy... . abc123...
 *
 * - HEADER: says "this is a JWT, signed with HS256"
 * - PAYLOAD: contains user data (user_id, email, role) — NOT encrypted, just signed
 * - SIGNATURE: a hash of header+payload using our JWT_SECRET
 *
 * Anyone can READ the payload (it's base64, not encrypted).
 * But nobody can FORGE it without knowing the secret.
 * So when the server receives a JWT, it re-computes the signature
 * and checks it matches → if yes, the token is genuine.
 */

import jwt from 'jsonwebtoken';

// This is what we store inside every JWT
export interface JWTPayload {
  user_id: number;
  email: string;
  role: 'admin' | 'organizer' | 'attendee' | 'gate_staff';
}

// Read the secret from environment — NEVER hardcode this
const JWT_SECRET = process.env.JWT_SECRET!;
if (!JWT_SECRET) {
  throw new Error('JWT_SECRET is not set in .env.local');
}

// How long tokens stay valid (7 days)
const JWT_EXPIRES_IN = '7d';

/**
 * Create a signed JWT for a user.
 * Called after login/register to give the user their token.
 */
export function signToken(payload: JWTPayload): string {
  return jwt.sign(payload, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN });
}

/**
 * Verify and decode a JWT string.
 * Returns the payload if valid, throws if tampered or expired.
 */
export function verifyToken(token: string): JWTPayload {
  return jwt.verify(token, JWT_SECRET) as JWTPayload;
}

/**
 * Extract the logged-in user from a Request object.
 * Reads the "token" cookie, verifies it, returns the user payload.
 * Returns null if no token or token is invalid (user is not logged in).
 *
 * LEARNING: We use an HttpOnly cookie (set server-side) rather than
 * localStorage because HttpOnly cookies can't be read by JavaScript
 * in the browser — this prevents XSS attacks from stealing the token.
 */
export function getUser(request: Request): JWTPayload | null {
  try {
    // Parse the Cookie header manually (works in Route Handlers)
    const cookieHeader = request.headers.get('cookie') ?? '';
    const cookies = Object.fromEntries(
      cookieHeader.split(';').map((c) => {
        const [k, ...v] = c.trim().split('=');
        return [k, v.join('=')];
      })
    );

    const token = cookies['token'];
    if (!token) return null;

    return verifyToken(token);
  } catch {
    // Token missing, expired, or tampered → treat as unauthenticated
    return null;
  }
}

/**
 * Like getUser() but throws a 401 Response if not logged in.
 * Use this in protected route handlers so you don't repeat the check.
 *
 * Usage in a route handler:
 *   const user = requireUser(request);  // throws 401 if not logged in
 *   // user.role, user.user_id, user.email are all available here
 */
export function requireUser(request: Request): JWTPayload {
  const user = getUser(request);
  if (!user) {
    throw new Response(JSON.stringify({ error: 'Unauthorized — please log in' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    });
  }
  return user;
}

/**
 * Require a specific role. Throws 403 if the user has the wrong role.
 *
 * Usage:
 *   const user = requireRole(request, ['admin', 'organizer']);
 */
export function requireRole(
  request: Request,
  allowedRoles: JWTPayload['role'][]
): JWTPayload {
  const user = requireUser(request);
  if (!allowedRoles.includes(user.role)) {
    throw new Response(
      JSON.stringify({ error: `Forbidden — requires role: ${allowedRoles.join(' or ')}` }),
      { status: 403, headers: { 'Content-Type': 'application/json' } }
    );
  }
  return user;
}
