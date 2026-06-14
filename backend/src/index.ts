import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import dotenv from 'dotenv';
dotenv.config();

import { pool } from './db/pool';
import { runMigrations } from './db/migrations';
import { reconcileAcademySchemas } from './db/academyMigrations';
import { errorHandler, notFound } from './middleware/errorHandler';
import { startKeepAlive } from './utils/keepAlive';
import { checkReady } from './utils/insightface';

import authRoutes from './routes/auth';
import academyRoutes from './routes/academy';
import academyCoursesRoutes from './routes/academyCourses';
import academyStudentsRoutes from './routes/academyStudents';
import academyFeesRoutes from './routes/academyFees';
import academyAttendanceRoutes from './routes/academyAttendance';
import academyParentRoutes from './routes/academyParent';
import academyQrRoutes from './routes/academyQr';
import academyAcademicYearsRoutes from './routes/academyAcademicYears';
import superAdminRoutes from './routes/superAdmin';
import studentRoutes from './routes/students';
import attendanceRoutes from './routes/attendance';
import scanRoutes from './routes/scan';
import reportRoutes from './routes/reports';
import settingsRoutes from './routes/settings';

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors({
  origin: '*',
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'X-Kiosk-Key'],
}));

app.use(helmet({ contentSecurityPolicy: false }));
app.use(morgan('combined'));
// 5 MB covers face-scan payloads (base64 JPEG × 5 ≈ 2 MB max)
app.use(express.json({ limit: '5mb' }));
app.use(express.urlencoded({ extended: true, limit: '5mb' }));

// Health check — exempt from rate limiting
app.get('/api/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    const base = {
      success: true,
      status: 'ok',
      db: 'connected',
      server: 'Render',
      database: 'Neon PostgreSQL',
      timestamp: new Date().toISOString(),
      uptime: process.uptime(),
    };
    // Optional InsightFace readiness probe — used by the scan-screen warmup.
    // Gated behind ?include=insightface so the keep-alive ping stays cheap.
    if (req.query.include === 'insightface') {
      const insightface = await checkReady();
      res.json({ ...base, insightface });
      return;
    }
    res.json(base);
  } catch (err) {
    res.status(500).json({ success: false, status: 'error', db: 'disconnected' });
  }
});

app.use('/api/auth',               authRoutes);
app.use('/api/academy',            academyRoutes);
app.use('/api/academy/courses',    academyCoursesRoutes);
app.use('/api/academy/students',   academyStudentsRoutes);
app.use('/api/academy/fees',       academyFeesRoutes);
app.use('/api/academy/attendance', academyAttendanceRoutes);
app.use('/api/academy/parent',     academyParentRoutes);
app.use('/api/academy/qr-codes',       academyQrRoutes);
app.use('/api/academy/academic-years', academyAcademicYearsRoutes);
app.use('/api/super-admin/academies',  superAdminRoutes);
app.use('/api/students',    studentRoutes);
app.use('/api/attendance',  attendanceRoutes);
app.use('/api/attendance',  scanRoutes);
app.use('/api/reports',     reportRoutes);
app.use('/api/settings',    settingsRoutes);

app.get('/api/routes', (_req, res) => {
  const routes: string[] = [];
  app._router.stack.forEach((middleware: any) => {
    if (middleware.route) {
      routes.push(`${Object.keys(middleware.route.methods).join(',').toUpperCase()} ${middleware.route.path}`);
    } else if (middleware.name === 'router') {
      middleware.handle.stack.forEach((handler: any) => {
        if (handler.route) {
          routes.push(`${Object.keys(handler.route.methods).join(',').toUpperCase()} ${handler.route.path}`);
        }
      });
    }
  });
  res.json({ routes });
});

app.use(notFound);
app.use(errorHandler);

async function start(): Promise<void> {
  try {
    await runMigrations();
    console.log('✅ Database migrations complete');

    // Ensure all existing academy schemas have the latest columns
    await reconcileAcademySchemas();

    const server = app.listen(Number(PORT), '0.0.0.0', () => {
      console.log(`🚀 EduScan backend running on port ${PORT}`);
      console.log(`🌍 Environment: ${process.env.NODE_ENV}`);
      console.log(`🗄️  Database: Neon PostgreSQL`);

      const serverUrl = process.env.RENDER_EXTERNAL_URL || `http://localhost:${PORT}`;
      startKeepAlive(serverUrl);
    });

    server.on('error', (err) => {
      console.error('❌ Server error:', err);
      process.exit(1);
    });
  } catch (err) {
    console.error('❌ Fatal startup error:', err);
    process.exit(1);
  }
}

process.on('uncaughtException', (err) => {
  console.error('❌ Uncaught Exception:', err);
  process.exit(1);
});

process.on('unhandledRejection', (reason) => {
  console.error('❌ Unhandled Rejection:', reason);
  process.exit(1);
});

start();

export default app;
