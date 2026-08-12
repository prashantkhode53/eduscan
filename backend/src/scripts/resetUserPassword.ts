/**
 * One-off: reset an academy user's login password.
 *
 * Bcrypt is one-way — you cannot recover the old password. This sets a NEW
 * known password by generating a fresh cost-12 hash and updating the row,
 * matching how academyMigrations.ts seeds the first admin.
 *
 * Usage (from backend/):
 *   npx ts-node src/scripts/resetUserPassword.ts <academy_slug> <email> <newPassword>
 *
 * Example:
 *   npx ts-node src/scripts/resetUserPassword.ts acme admin@acme.com 'Str0ng@Pass'
 *
 * Requires DATABASE_URL in the environment (same .env the backend uses).
 */
import bcrypt from 'bcrypt';
import { academyExec, sharedPool } from '../db/poolManager';

async function main(): Promise<void> {
  const [slug, email, newPassword] = process.argv.slice(2);

  if (!slug || !email || !newPassword) {
    console.error('Usage: resetUserPassword.ts <academy_slug> <email> <newPassword>');
    process.exit(1);
  }
  if (newPassword.length < 8) {
    console.error('Password must be at least 8 characters.');
    process.exit(1);
  }

  // Cost 12 — matches academyMigrations.ts and produces a $2b$12$... hash.
  const passwordHash = await bcrypt.hash(newPassword, 12);

  const { rowCount, rows } = await academyExec<{ id: string; email: string }>(
    slug,
    `UPDATE users
        SET password_hash    = $1,
            failed_attempts  = 0
      WHERE lower(email) = lower($2)
      RETURNING id, email`,
    [passwordHash, email],
  );

  if (rowCount === 0) {
    console.error(`No user with email "${email}" in schema academy_${slug}.`);
    process.exit(2);
  }

  console.log(`Updated ${rowCount} row(s):`, rows);
  console.log(`New login password for ${email}: ${newPassword}`);
}

main()
  .catch((err) => {
    console.error('Failed:', err);
    process.exitCode = 1;
  })
  .finally(() => {
    void sharedPool.end();
  });
