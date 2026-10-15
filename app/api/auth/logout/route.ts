/**
 * app/api/auth/logout/route.ts
 *
 * POST /api/auth/logout
 *
 * WHAT THIS DOES:
 * Clears the session cookie by setting Max-Age=0.
 */

export async function POST() {
  const response = Response.json({ message: 'Logged out successfully' });
  response.headers.set(
    'Set-Cookie',
    'token=; HttpOnly; Path=/; Max-Age=0; SameSite=Lax'
  );
  return response;
}
