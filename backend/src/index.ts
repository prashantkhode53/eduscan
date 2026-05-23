import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import dotenv from 'dotenv';
dotenv.config();

import { pool } from './db/pool';
import { runMigrations } from './db/migrations';
import { defaultLimiter } from './middleware/rateLimiter';
import { errorHandler, notFound } from './middleware/errorHandler';
import { startKeepAlive } from './utils/keepAlive';

import authRoutes from './routes/auth';
import studentRoutes from './routes/students';
import attendanceRoutes from './routes/attendance';
import scanRoutes from './routes/scan';
import reportRoutes from './routes/reports';
import settingsRoutes from './routes/settings';

const app = express();
const PORT = process.env.PORT ?? 3000;

// CORS — allow all origins so Flutter mobile app works on any network
app.use(cors({
  origin: '*',
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'X-Kiosk-Key'],
}));

app.use(helmet({ contentSecurityPolicy: false }));
app.use(morgan('combined'));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));
app.use(defaultLimiter);

// Health check — Render pings this; keep-alive also uses it
app.get('/api/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({
      success: true,
      status: 'ok',
      db: 'connected',
      server: 'Render',
      database: 'Neon PostgreSQL',
      timestamp: new Date().toISOString(),
      uptime: process.uptime(),
    });
  } catch (err) {
    res.status(500).json({ success: false, status: 'error', db: 'disconnected' });
  }
});

app.use('/api/auth', authRoutes);
app.use('/api/students', studentRoutes);
app.use('/api/attendance', attendanceRoutes);
app.use('/api/attendance', scanRoutes);
app.use('/api/reports', reportRoutes);
app.use('/api/settings', settingsRoutes);

app.use(notFound);
app.use(errorHandler);

async function bootstrap(): Promise<void> {
  try {
    await runMigrations();
    console.log('✅ Database migrations complete');
    app.listen(PORT, () => {
      console.log(`🚀 EduScan backend running on port ${PORT}`);
      console.log(`🌍 Environment: ${process.env.NODE_ENV ?? 'development'}`);
      console.log(`🗄️  Database: Neon PostgreSQL`);
    });

    const serverUrl = process.env.RENDER_EXTERNAL_URL ?? `http://localhost:${PORT}`;
    startKeepAlive(serverUrl);
  } catch (err) {
    console.error('❌ Failed to start server:', err);
    process.exit(1);
  }
}

bootstrap();

export default app;
