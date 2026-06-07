import 'dotenv/config';
import { reconcileAcademySchemas } from './academyMigrations';
import { pool } from './pool';

(async () => {
  try {
    console.log('Running reconcileAcademySchemas...');
    await reconcileAcademySchemas();
    console.log('Done.');
  } catch (err) {
    console.error('Migration failed:', err);
    process.exit(1);
  } finally {
    await pool.end();
  }
})();
