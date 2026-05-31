import { Request, Response, NextFunction } from 'express';

export class AppError extends Error {
  public statusCode: number;
  public isOperational: boolean;

  constructor(message: string, statusCode: number) {
    super(message);
    this.statusCode = statusCode;
    this.isOperational = true;
    Error.captureStackTrace(this, this.constructor);
  }
}

export const errorHandler = (
  err: Error | AppError,
  _req: Request,
  res: Response,
  _next: NextFunction
): void => {
  const statusCode = (err as AppError).statusCode ?? 500;
  const isOperational = (err as AppError).isOperational ?? false;

  const isProd = process.env.NODE_ENV === 'production';

  if (!isProd || isOperational) {
    console.error(`[Error] ${err.message}`);
  } else {
    // Always log the full error + stack server-side so 500s stay diagnosable.
    console.error('[Error] Unhandled server error:', err);
  }

  // Operational errors (AppError: 400/401/403/404/409/422) carry a user-safe
  // message. Unexpected errors get a generic message in production so internal
  // details (SQL text, stack traces, table names) are never leaked to clients;
  // the full error is logged above. Non-production still surfaces detail+stack.
  const clientMessage = isOperational
    ? err.message
    : isProd
      ? 'Something went wrong. Please try again.'
      : `Server error: ${err.message}`;

  res.status(statusCode).json({
    success: false,
    message: clientMessage,
    ...(!isProd && { stack: err.stack }),
  });
};

export const notFound = (_req: Request, res: Response): void => {
  res.status(404).json({ success: false, message: 'Route not found' });
};
