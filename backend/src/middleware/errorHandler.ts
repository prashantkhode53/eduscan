import { Request, Response, NextFunction } from 'express';

export class AppError extends Error {
  public statusCode: number;
  public isOperational: boolean;
  public data?: Record<string, unknown>;

  constructor(message: string, statusCode: number, data?: Record<string, unknown>) {
    super(message);
    this.statusCode = statusCode;
    this.isOperational = true;
    this.data = data;
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

  const appErr = err as AppError;
  res.status(statusCode).json({
    success: false,
    message: clientMessage,
    // Include structured data only for operational errors (e.g. FACE_DUPLICATE 409)
    // — never leak internal data from unexpected 500s.
    ...(isOperational && appErr.data ? { data: appErr.data } : {}),
    ...(!isProd && { stack: err.stack }),
  });
};

export const notFound = (_req: Request, res: Response): void => {
  res.status(404).json({ success: false, message: 'Route not found' });
};
