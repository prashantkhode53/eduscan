import { query } from '../db/pool';

export async function generateStudentId(): Promise<string> {
  const year = new Date().getFullYear().toString();
  const rows = await query<{ id: string }>(
    `SELECT id FROM students WHERE id LIKE $1 ORDER BY id DESC LIMIT 1`,
    [`STU-${year}-%`]
  );

  let nextNum = 1;
  if (rows.length > 0) {
    const lastId = rows[0].id;
    const parts = lastId.split('-');
    const lastNum = parseInt(parts[2], 10);
    if (!isNaN(lastNum)) {
      nextNum = lastNum + 1;
    }
  }

  const padded = nextNum.toString().padStart(5, '0');
  return `STU-${year}-${padded}`;
}
