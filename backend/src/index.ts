import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import dotenv from 'dotenv';
dotenv.config();

import { pool } from './db/pool';
import { runMigrations } from './db/migrations';
import { errorHandler, notFound } from './middleware/errorHandler';
import { startKeepAlive } from './utils/keepAlive';

import authRoutes from './routes/auth';
import academyRoutes from './routes/academy';
import studentRoutes from './routes/students';
import attendanceRoutes from './routes/attendance';
import scanRoutes from './routes/scan';
import reportRoutes from './routes/reports';
import settingsRoutes from './routes/settings';
import { whatsappRouter, runWhatsAppMigrations, whatsappService } from './whatsapp';

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors({
  origin: '*',
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'X-Kiosk-Key'],
}));

app.use(helmet({ contentSecurityPolicy: false }));
app.use(morgan('combined'));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// Health check is exempt from rate limiting — used by keep-alive and Flutter warm-up
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
app.use('/api/academy', academyRoutes);
app.use('/api/students', studentRoutes);
app.use('/api/attendance', attendanceRoutes);
app.use('/api/attendance', scanRoutes);
app.use('/api/reports', reportRoutes);
app.use('/api/settings', settingsRoutes);
app.use('/whatsapp', whatsappRouter);
console.log('✅ WhatsApp routes mounted at /whatsapp');

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

    await runWhatsAppMigrations();

    // WhatsApp client starts non-blocking — its failure never crashes the server
    whatsappService.initialize().catch((err: unknown) => {
      const msg = err instanceof Error ? err.message : String(err);
      console.error('❌ WhatsApp init error:', msg);
    });

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
